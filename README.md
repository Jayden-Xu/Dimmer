# Dimmer

macOS 菜单栏小工具：当前聚焦的窗口保持原样，其余窗口和桌面压暗。
多显示器时每块屏各自保留一个亮窗口：焦点所在屏是焦点窗口，其他屏是各自最前面的窗口。

## 构建

```bash
./build.sh
```

依次完成：`swiftc -O` 编译 → 拼装 `build/Dimmer.app` → 签名 → 复制到 `~/Applications/Dimmer.app` 并重启。

- App 图标由 `icon.swift` 绘制，只在该文件改动后重新生成（缓存在 `build/AppIcon.icns`）。菜单栏图标是同一构图的单色版，启动时画一次。

- 需要 Xcode Command Line Tools（`swiftc`），目标 macOS 14+，无第三方依赖。
- 签名用钥匙串里的自签名证书 **Dimmer Dev**；没有的话脚本会自动创建。
  第一次签名时系统会弹窗询问 codesign 能否使用这个私钥：输入登录密码，选 **始终允许**。
- 证书不可用时退回 ad-hoc 签名，此时每次重新构建后都要重新勾选辅助功能。
- 快捷键默认 ⌃⌥⌘D，可改：`defaults write com.jayden.dimmer hotKey "ctrl+opt+cmd+d"`，重启 Dimmer 生效。

## 授权

- **辅助功能**：用于跟随同一 app 内切换 / 新开 / 关闭窗口。首次启动会弹系统提示；
  没授权时菜单里有「Grant Accessibility Access…」。授权后自动生效，不用重启；用 Dimmer Dev 证书签名时重新构建不会失效。
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
- 非焦点屏上，不在前台的 app 关闭窗口时收不到事件，那块屏要等下一次切换才更新。
- 没有辅助功能权限时，同一 app 内新开或切换窗口不会被跟随，直到下一次切换 app。

## 资源占用实测

环境：MacBook Air M2（macOS 26.6.2），内置屏 2560×1664 + 外接 DELL 1080×1920。

- **内存**（physical footprint，即活动监视器「内存」列）：启动约 **13 MB**。第一次打开菜单后约 +3 MB（AppKit 菜单绘制缓存），之后反复打开不再增长。
  - 内存大头是 ColorSync 色彩转换表（每个约 1 MB，按「源色彩空间 × 屏幕 profile」缓存）。overlay 窗口用 device RGB 色彩空间，
    纯黑填充不需要色彩匹配，不会再为每块屏建转换表（旧版启动 16–18 MB）。
  - 状态栏图标的转换表（AppKit 渲染 template 图标）是固定成本，无法避免。
- **CPU**：空闲时为 0（全部事件驱动，无常驻 Timer）；每次切换 app 约 4 ms。
- **WindowServer**：纯压暗与关闭效果相比，WindowServer CPU 和 GPU 利用率的差别在测量噪声以内。
