# Dimmer

macOS 菜单栏小工具：当前聚焦的窗口保持原样，同一块屏幕上的其余窗口和桌面压暗。

## 构建

```bash
./build.sh
```

依次完成：`swiftc -O` 编译 → 拼装 `build/Dimmer.app` → 签名 → 复制到 `~/Applications/Dimmer.app` 并重启。

- 需要 Xcode Command Line Tools（`swiftc`），目标 macOS 14+，无第三方依赖。
- 签名用钥匙串里的自签名证书 **Dimmer Dev**；没有的话脚本会自动创建。
  第一次签名时系统会弹窗询问 codesign 能否使用这个私钥：输入登录密码，选 **始终允许**。
- 证书不可用时退回 ad-hoc 签名，此时每次重新构建后都要重新勾选辅助功能。
- 快捷键默认 ⌃⌥⌘D，可改：`defaults write com.jayden.dimmer hotKey "ctrl+opt+cmd+d"`，重启 Dimmer 生效。

## 授权

- **辅助功能**：用于跟随同一 app 内切换 / 新开 / 关闭窗口。首次启动会弹系统提示；
  没授权时菜单里有「去授权辅助功能…」。授权后自动生效，不用重启；用 Dimmer Dev 证书签名时重新构建不会失效。
- 没有授权也能用，只是只跟随「切换 app」。
- 快捷键和开机启动不需要额外权限。

## 已知问题

- **用了私有 API**，都通过 `dlsym` 动态加载，缺失时自动降级、不会崩溃：
  - `CGSCopyManagedDisplaySpaces` / `CGSAddWindowsToSpaces` 等：每个桌面 Space 放一个 overlay，全屏 Space 里不放。
    缺失时退回「一个 `.canJoinAllSpaces` overlay」，全屏 Space 靠「焦点窗口铺满屏幕」判断并隐藏，进出全屏可能闪一下。
  - `_AXUIElementGetWindow`：拿到真正的焦点窗口。缺失时用「前台 app 最上面的窗口」代替。
- 在 macOS 26 上，`canJoinAllSpaces` 的窗口即使不加 `.fullScreenAuxiliary` 也会出现在全屏 Space 里，所以改用每个桌面 Space 一个 overlay。
- 用 `.transient` 而不是 `.stationary`：`.stationary` 会让 overlay 在 Mission Control 里停在原处，盖住窗口缩略图。
  进出 Mission Control 时系统会对 overlay 做约 50 ms 的淡入淡出。
- **激活时序**：app 被激活的通知比它真正把窗口抬到最前早 50–250 ms。Dimmer 在事件之后保持原画面，每 2 ms 查一次窗口层级，
  最多 0.7 s，等焦点窗口真正到了最前再一次性重排。这是事件触发、有上限的短暂检查，空闲时不运行；每次切换约耗 4 ms CPU。
- 前台 app 被激活了却没抬起任何窗口（例如点击桌面时 Finder 的窗口留在后面），要等 0.7 s 后才隐藏 overlay。
- 第一次进入一个新建的桌面 Space 时，要等焦点窗口就位后才开始压暗。
- 只压暗焦点窗口所在的那块屏幕，其他屏幕不处理。
- 没有辅助功能权限时，同一 app 内新开或切换窗口不会被跟随，直到下一次切换 app。

## 资源占用实测

环境：MacBook（Apple Silicon，macOS 26.6.2），内置屏 2560×1664 + 外接 1080×1920。

- **内存**（physical footprint，即活动监视器「内存」列）：约 **11 MB**，切换 app 40 次、进出全屏 3 次后仍为 11 MB。
  与一个只有状态栏图标、什么都不做的空 AppKit 程序相同（11 MB），即 AppKit 的下限。
  - 状态栏图标是启动时画好的静态位图，之后不再改变。早期版本用动态绘制的图标，菜单栏每次重绘都会让 ColorSync 多缓存约 1 MB，
    用久了会涨到 20 MB 以上。
- **CPU**：空闲 60 s 的 CPU 时间增量为 0（全部事件驱动，无常驻 Timer）；10 次 app 切换共约 40 ms。
- **WindowServer**：纯压暗与关闭效果相比，WindowServer CPU 和 GPU 利用率的差别在测量噪声以内
  （静止画面约 13–14% / 42%，背景窗口持续动画约 29–30% / 55%；基线来自测量期间终端里的动画）。
