这是一个快捷键工具， 在Windows上是利用了autohotkey，在macOS上是用了[Karabiner-Elements](https://karabiner-elements.pqrs.org/)
在任务计划程序中导入使用。可以以管理员身份开机自启动，不弹窗。

Windows 更新 `.ahk` 后按 `CapsLock + F5` 重载。若已导入旧版计划任务，
还需在任务的“条件”中取消“如果计算机改用电池电源则停止”，或重新导入更新后的 XML。

macOS 参考 https://github.com/lianginx/capslock-yes


macOS 导入， 浏览器打开：

karabiner://karabiner/assets/complex_modifications/import?url=https://raw.githubusercontent.com/iuxt/capslock-pro/refs/heads/master/macOS/Karabiner-Elements.json

更新后需要重新导入一次（先在 Complex Modifications 里 Remove 旧的规则，再点上面的链接导入）。

也可以在仓库目录运行更新脚本，一次完成 Swift 编译和当前 Karabiner profile 的规则更新：

```bash
./macOS/update.sh
```

脚本会保留其他 Karabiner 规则，并将修改前的配置备份为
`~/.config/karabiner/karabiner.json.capslock-pro.backup`。首次使用前请先启动一次
Karabiner-Elements，让它生成配置文件。源码没有变化时脚本会保留现有可执行文件，避免
反复覆盖导致 macOS 辅助功能授权失效；如需强制重新编译，可执行
`./macOS/update.sh --force`。
若要安装到其他目录，可设置 `CAPSLOCK_PRO_BIN_DIR`，例如
`CAPSLOCK_PRO_BIN_DIR="$HOME/bin" ./macOS/update.sh`。脚本会将实际安装路径同步到
当前 profile 的窗口快捷键规则和 Karabiner 规则资源；直接导入仓库中的 JSON 仍使用默认路径。

如需安装到其他目录，可运行 `CAPSLOCK_PRO_BIN_DIR="/自定义目录" ./macOS/update.sh`。
脚本会同时更新当前 profile 和规则资源中的调用路径；自定义目录安装请使用此脚本，
网页导入的规则使用默认目录 `~/.local/bin`。

Windows 和 macOS 均可按 `CapsLock + r`，将当前窗口居中，并在当前屏幕可用区域
80% 和 50% 的宽高之间切换。

## macOS 快捷键

单独按下或长按 CapsLock 不再切换大写锁定，避免组合键未按完整时误开大写。
需要切换大写锁定时使用 `CapsLock + Esc`（与 Windows 一致）。如果更新前大写已经开启，
更新后按一次 `CapsLock + Esc` 关闭即可。此规则修改需要运行 `./macOS/update.sh`
或删除旧规则后重新导入才能生效。

macOS 防误触：同一次按住 CapsLock 期间，使用过方向、行首行尾或窗口快捷键后，
再按 Esc 会正常发送 Esc，不切换大写。需要切换时，先松开 CapsLock 和 Esc，
再重新按住 CapsLock 并按 Esc；每轮按住 CapsLock 最多切换一次。
切换请求的时间记录在 `~/Library/Logs/CapsLock-Pro/caps-lock-toggle.log`，不记录输入内容。
若异常发生时没有对应记录，需继续排查系统或其他程序设置大写状态的路径。

| 快捷键 | 功能 |
| --- | --- |
| CapsLock + Esc | 切换大写锁定 |
| CapsLock + h / j / k / l | 左 / 下 / 上 / 右 |
| CapsLock + u / i | 行首 / 行尾（Mac 风格） |
| CapsLock + o | 在下方新起一行 |
| CapsLock + f | 切换当前窗口的原生全屏状态 |
| CapsLock + r | 将当前窗口居中，并在屏幕 80% 和 50% 两档大小之间切换 |
| CapsLock + n | 把当前窗口移动到下一个屏幕 |
| CapsLock + p | 把当前窗口移动到上一个屏幕 |
| CapsLock + 1 / 2 / 3 | 把当前窗口移动到第 1 / 2 / 3 个屏幕 |

## Swift 跨屏工具的使用方法

`move-window-display.swift` 是窗口跨屏功能的 Swift 版本，启动速度比 AppleScript 版本快。需要先在 macOS 上编译一次：

```bash
mkdir -p "$HOME/.local/bin"
swiftc -O macOS/src/move-window-display.swift -o "$HOME/.local/bin/move-window-display"
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

# 切换当前窗口的原生全屏状态
~/.local/bin/move-window-display fullscreen

# 将当前窗口居中，并在当前屏幕 80% 和 50% 两档大小之间切换
~/.local/bin/move-window-display resize

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

仓库提供的 `Karabiner-Elements.json` 默认调用编译后的 Swift 程序：

```text
"$HOME/.local/bin/move-window-display" --background next
"$HOME/.local/bin/move-window-display" --background prev
"$HOME/.local/bin/move-window-display" --background resize
"$HOME/.local/bin/move-window-display" --background 1
"$HOME/.local/bin/move-window-display" --background 2
"$HOME/.local/bin/move-window-display" --background 3
```

导入规则前需要先完成上面的编译安装。更新 Swift 源码后，重新编译即可，无需再次导入规则。

窗口快捷键通过独立后台进程执行，避免后续快捷键终止尚未完成的全屏切换。
窗口操作期间的新窗口命令会被忽略，请在动画结束后再次按键。
后台错误信息写入 `~/Library/Logs/CapsLock-Pro/window.log`。
本次升级同时修改了调用参数，需要运行 `./macOS/update.sh`，或编译后重新导入规则。

### 跨屏行为

默认使用的 Swift 版本见 `macOS/src/move-window-display.swift`，主要行为如下。
旧的 `macOS/move-window-to-display.applescript` 保留供参考，不包含本次 Swift 修复。

- 跨屏时保持窗口原尺寸；只有目标屏幕放不下时才会等比缩小，不会主动放大小窗口；
- 尽量保持窗口在屏幕中的相对位置，并自动校正到菜单栏和 Dock 之外的可视区域；
- 已铺满当前屏幕可用区域的窗口，跨屏后会尝试重新铺满目标屏幕；如果应用限制尺寸而无法铺满，只要窗口中心已进入目标屏幕，就保留实际大小，不会移回原屏幕；
- 最大化按窗口几何尺寸识别。应用自身仅放大到内容大小、没有铺满屏幕的 Zoom 窗口，按普通窗口处理；
- 只会使用屏幕的可视区域，不会压到菜单栏和 Dock；
- Karabiner 规则调用 `~/.local/bin/move-window-display`，该文件需要由 Swift 源码预先编译；
- 首次使用需要授权：**系统设置 → 隐私与安全性 → 辅助功能**，打开 `karabiner_grabber`（必要时也添加 `~/.local/bin/move-window-display`）；
- Swift 版本遇到原生全屏窗口时，会自动退出全屏、移动到目标显示器，然后在目标显示器恢复全屏；如果应用或 macOS 拒绝切换，会响一声提示音。
- 窗口操作始终绑定触发快捷键时的窗口；若应用在全屏切换时使原窗口对象失效，会报错停止，请等切换结束后重新按快捷键。

### macOS 回归检查

在 macOS 上运行 `python3 macOS/tests/test_macos.py`，检查编译、跨屏尺寸计算、
后台进程隔离、操作互斥和自定义目录安装。测试仅操作临时文件和测试进程，
不修改现用 Karabiner 配置，也不移动真实窗口。
