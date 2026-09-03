这是一个快捷键工具， 在Windows上是利用了autohotkey，在macOS上是用了[Karabiner-Elements](https://karabiner-elements.pqrs.org/)
在任务计划程序中导入使用。可以以管理员身份开机自启动，不弹窗。


macOS 参考 https://github.com/lianginx/capslock-yes


macOS 导入， 浏览器打开：

karabiner://karabiner/assets/complex_modifications/import?url=https://raw.githubusercontent.com/iuxt/capslock-pro/refs/heads/master/macOS/Karabiner-Elements.json

更新后需要重新导入一次（先在 Complex Modifications 里 Remove 旧的规则，再点上面的链接导入）。


## macOS 快捷键

| 快捷键 | 功能 |
| --- | --- |
| CapsLock + h / j / k / l | 左 / 下 / 上 / 右 |
| CapsLock + u / i | 行首 / 行尾（Mac 风格） |
| CapsLock + o | 在下方新起一行 |
| CapsLock + n | 把当前窗口移动到下一个屏幕 |
| CapsLock + p | 把当前窗口移动到上一个屏幕 |
| CapsLock + 1 / 2 / 3 | 把当前窗口移动到第 1 / 2 / 3 个屏幕 |

## Swift 跨屏工具的使用方法

`move-window-display.swift` 是窗口跨屏功能的 Swift 版本，启动速度比 AppleScript 版本快。需要先在 macOS 上编译一次：

```bash
mkdir -p "$HOME/.local/bin"
swiftc -O move-window-display.swift -o "$HOME/.local/bin/move-window-display"
```

如果系统提示找不到 `swiftc`，先安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

编译后可以直接运行：

```bash
# 移到下一个屏幕（不传参数时也是 next）
~/.local/bin/move-window-display next

# 移到上一个屏幕
~/.local/bin/move-window-display prev

# 移到指定屏幕，序号范围为 1 到 9
~/.local/bin/move-window-display 1
~/.local/bin/move-window-display 2

# 查看帮助
~/.local/bin/move-window-display --help
```

首次运行前，需要打开 **系统设置 → 隐私与安全性 → 辅助功能**：

- 从终端运行时，允许所使用的终端程序控制电脑；
- 从 Karabiner-Elements 调用时，允许 `karabiner_grabber` 控制电脑；
- 如果仍然提示“缺少辅助功能权限”，点击列表下方的 `+`，添加 `~/.local/bin/move-window-display`。

遇到移动或缩放问题时，可以打开调试日志：

```bash
MWD_DEBUG=1 ~/.local/bin/move-window-display next
```

更新源码后，重新执行编译命令即可覆盖旧版本。

### 在 Karabiner-Elements 中调用 Swift 版本

把对应规则的 `shell_command` 设置为以下命令：

```text
"$HOME/.local/bin/move-window-display" next
"$HOME/.local/bin/move-window-display" prev
"$HOME/.local/bin/move-window-display" 1
"$HOME/.local/bin/move-window-display" 2
"$HOME/.local/bin/move-window-display" 3
```

当前仓库提供的 `Karabiner-Elements.json` 仍然内嵌 AppleScript，因此不安装 Swift 版本也能直接使用。要让快捷键使用 Swift 版本，需要修改 JSON 中相应的 `shell_command`，然后重新导入规则。

### 跨屏行为

Swift 版本见 `move-window-display.swift`，AppleScript 版本见 `move-window-to-display.applescript`。它们的主要行为如下：

- 屏幕分辨率不同也可以：按两个屏幕的面积比缩放窗口，宽高比保持不变（不会被拉伸），来回移动后尺寸能还原；
- 窗口某一方向贴满了源屏幕时，到目标屏幕会继续贴满该方向；
- 窗口过小时会放大到目标屏幕宽度的 20%；应用自身的最小/最大尺寸会被尊重，位置会自动校正回屏幕内；
- 只会使用屏幕的可视区域，不会压到菜单栏和 Dock；
- AppleScript 已内嵌在 `Karabiner-Elements.json` 里，导入即可用（修改脚本时需要同步两处）；
- 首次使用需要授权：**系统设置 → 隐私与安全性 → 辅助功能**，打开 `karabiner_grabber`（必要时也加上 `osascript`）；
- Swift 版本遇到原生全屏窗口时，会自动退出全屏、移动到目标显示器，然后在目标显示器恢复全屏；如果应用或 macOS 拒绝切换，会响一声提示音。
