import AVFoundation

/// Focus music, made up as it plays: no audio files, nothing stored.
///
/// Built for steady background sound rather than for listening: instrumental, soft timbres with no sharp
/// attacks, a slow steady pulse (78–88 BPM, a soft kick on every beat), and a key and tempo that stay
/// fixed for the whole focus. What changes is the music on top: every two bars the chord moves to one that
/// fits after it, and the plucked notes wander step by step, with gaps. Each focus picks a new key and tempo.
///
/// The engine exists only while music plays (it fades out for 1.2 s, then is torn down), so an idle dimmer
/// holds no audio resources.
@MainActor
final class MusicPlayer {
    private var engine: AVAudioEngine?
    private var synth: Synth?
    private var generation = 0

    func setPlaying(_ on: Bool) {
        if on {
            generation += 1
            if let synth { synth.target = 1; return }  // fading out: bring it back
            start()
        } else {
            guard let synth else { return }
            synth.target = 0
            generation += 1
            let mine = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == mine else { return }
                    self.engine?.stop()
                    self.engine = nil
                    self.synth = nil
                }
            }
        }
    }

    private func start() {
        let engine = AVAudioEngine()
        let rate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let synth = Synth(rate: Float(rate))
        let node = AVAudioSourceNode(format: format) { _, _, frames, list in
            synth.render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(list))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        self.engine = engine
        self.synth = synth
        synth.target = 1
    }
}

/// Real-time generator. `render` runs on the audio thread; `target` is the only thing the main thread touches.
private final class Synth: @unchecked Sendable {
    nonisolated(unsafe) var target: Float = 0

    /// Everything is low-passed at 1.1 kHz, so it is made at 12 kHz and stretched to the device's rate by
    /// linear interpolation: a quarter of the work.
    private let rate: Float = 12000
    private let advance: Float  // internal samples per output sample
    private let outRate: Float
    private var frac: Float = 0, prev: Float = 0, cur: Float = 0
    private var gain: Float = 0
    private var rng: UInt64 = UInt64.random(in: 1...UInt64.max)

    // Chords in C (bass note, upper tones, MIDI) and which may follow each.
    private static let chords: [(bass: Int, tones: [Int], next: [Int])] = [
        (36, [60, 64, 67, 71], [1, 2, 3, 5]),  // 0 C
        (33, [57, 60, 64, 67], [2, 4, 0, 3]),  // 1 Am
        (41, [57, 60, 65, 69], [0, 3, 4, 1]),  // 2 F
        (43, [55, 59, 62, 67], [0, 1, 5, 2]),  // 3 G
        (38, [57, 60, 65, 69], [3, 2, 1]),     // 4 Dm
        (40, [55, 59, 62, 67], [1, 2, 4]),     // 5 Em
    ]
    private static let stepsPerChord = 16  // two bars of eighth notes

    private let transpose: Float
    private let eighth: Int  // samples
    private var untilStep = 0
    private var step = 0
    private var chord = 0
    private var pitch = 0  // index into the pluck pool, wanders

    private struct Voice {
        var f: Float = 0, phase: Float = 0, amp: Float = 0
        var age = 0, length = 0, attack = 1, release = 1
        var level: Float = 1, decay: Float = 1, h2: Float = 0
        var live = false
    }
    private var voices = [Voice](repeating: Voice(), count: 16)
    private var kickAge = Int.max, shakerAge = Int.max
    private var hat: Float = 0
    private var low: Float = 0

    // Comb filters for a little room.
    private var combs: [(buf: [Float], pos: Int, fb: Float)]

    init(rate outRate: Float) {
        self.outRate = outRate
        advance = 12000 / outRate
        let bpm = Float.random(in: 78...88)
        eighth = Int(12000 * 60 / bpm / 2)
        transpose = Float(Int.random(in: -3...3))
        combs = [(0.0297, 0.62), (0.0371, 0.60), (0.0411, 0.57)].map {
            (buf: [Float](repeating: 0, count: Int(12000 * $0.0)), pos: 0, fb: Float($0.1))
        }
        chord = 0
        step = Self.stepsPerChord - 1  // first step() starts a chord
    }

    private func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    private func hz(_ midi: Int) -> Float { 440 * pow(2, (Float(midi) + transpose - 69) / 12) }

    private func add(_ midi: Int, seconds: Float, amp: Float, attack: Float, release: Float,
                     decay: Float = 0, h2: Float) {
        guard let i = voices.firstIndex(where: { !$0.live }) else { return }
        voices[i] = Voice(f: hz(midi), phase: 0, amp: amp, age: 0, length: Int(seconds * rate),
                          attack: max(1, Int(attack * rate)), release: max(1, Int(release * rate)),
                          level: 1, decay: decay > 0 ? exp(-decay / rate) : 1, h2: h2, live: true)
    }

    private func nextStep() {
        step += 1
        if step >= Self.stepsPerChord {
            step = 0
            chord = Self.chords[chord].next.randomElement(using: &rng) ?? 0
            let c = Self.chords[chord]
            let seconds = Float(Self.stepsPerChord * eighth) / rate
            for t in c.tones { add(t, seconds: seconds, amp: 0.03, attack: 1.2, release: 1.5, decay: 0.45, h2: 0.06) }
        }
        let c = Self.chords[chord]
        // The bass is a soft note on the first beat of each bar that dies away, an octave up from a
        // chord root: a held low note sounded like a hum.
        if step % 8 == 0 { add(c.bass + 12, seconds: 1.2, amp: 0.10, attack: 0.04, release: 0.5, decay: 1.6, h2: 0.1) }
        if step % 2 == 0, rand() >= 0.35 {  // a note only on a beat, and 35 % of those stay silent
            let pool = c.tones.map { $0 + 12 }
            pitch = min(pool.count - 1, max(0, pitch + [-2, -1, -1, 1, 1, 2][Int(rand() * 6) % 6]))
            let velocity = (0.55 + 0.45 * rand()) * (step % 2 == 0 ? 1 : 0.75)
            add(pool[pitch], seconds: 0.1, amp: 0.04 * velocity, attack: 0.012, release: 0.35, decay: 4, h2: 0.15)
        }
        if step % 2 == 0 { kickAge = 0 }
        else if rand() < 0.8 { shakerAge = 0 }
    }

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let lowCoef = 1 - exp(-2 * Float.pi * 1100 / rate)
        let slew: Float = 1 / (1.2 * outRate)
        for n in 0..<frames {
            frac += advance
            if frac >= 1 { frac -= 1; prev = cur; cur = tick(lowCoef) }
            if gain < target { gain = min(target, gain + slew) } else if gain > target { gain = max(target, gain - slew) }

            let y = (prev + (cur - prev) * frac) * gain
            for b in 0..<buffers.count {
                buffers[b].mData?.assumingMemoryBound(to: Float.self)[n] = y
            }
        }
    }

    /// One sample at the internal rate.
    private func tick(_ lowCoef: Float) -> Float {
        let twoPi = 2 * Float.pi
        if untilStep <= 0 { nextStep(); untilStep = eighth }
        untilStep -= 1
        do {
            var x: Float = 0
            for i in voices.indices where voices[i].live {
                let v = voices[i]
                let a = v.age
                var e: Float
                if a < v.attack { e = Float(a) / Float(v.attack) }
                else if a < v.length { e = 1 }
                else { e = 1 - Float(a - v.length) / Float(v.release) }
                if a >= v.length + v.release { voices[i].live = false; continue }
                e *= v.level
                voices[i].level = v.level * v.decay
                let p = v.phase
                x += v.amp * e * (sin(p) + (v.h2 > 0 ? v.h2 * sin(2 * p) : 0))
                voices[i].phase = p + twoPi * v.f / rate
                if voices[i].phase > twoPi * 64 { voices[i].phase -= twoPi * 64 }
                voices[i].age = a + 1
            }
            if kickAge < Int(0.18 * rate) {
                let t = Float(kickAge) / rate
                x += 0.10 * exp(-t * 15) * sin(twoPi * (46 + 80 * exp(-t * 26)) * t)
                kickAge += 1
            }
            if shakerAge < Int(0.06 * rate) {
                let t = Float(shakerAge) / rate
                let noise = rand() * 2 - 1
                hat = noise - 0.9 * hat
                x += 0.008 * exp(-t * 60) * hat
                shakerAge += 1
            }
            low += lowCoef * (x - low)
            var wet: Float = 0
            for k in combs.indices {
                let out = combs[k].buf[combs[k].pos]
                combs[k].buf[combs[k].pos] = low + combs[k].fb * out
                combs[k].pos = (combs[k].pos + 1) % combs[k].buf.count
                wet += out
            }
            return (low * 0.8 + wet * 0.07) * 2.0
        }
    }
}

extension Array {
    fileprivate func randomElement(using state: inout UInt64) -> Element? {
        guard !isEmpty else { return nil }
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return self[Int(state % UInt64(count))]
    }
}
