这是一个快捷键工具， 在Windows上是利用了autohotkey，在macOS上是用了[Karabiner-Elements](https://karabiner-elements.pqrs.org/)
在任务计划程序中导入使用。可以以管理员身份开机自启动，不弹窗。


macOS 参考 https://github.com/lianginx/capslock-yes


macOS 导入， 浏览器打开：

karabiner://karabiner/assets/complex_modifications/import?url=https://raw.githubusercontent.com/iuxt/capslock-pro/refs/heads/master/Karabiner-Elements.json

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

窗口跨屏移动的实现见 `move-window-to-display.applescript`：

- 屏幕分辨率不同也可以：按两个屏幕的面积比缩放窗口，宽高比保持不变（不会被拉伸），来回移动后尺寸能还原；
- 窗口某一方向贴满了源屏幕时，到目标屏幕会继续贴满该方向；
- 窗口过小时会放大到目标屏幕宽度的 20%；应用自身的最小/最大尺寸会被尊重，位置会自动校正回屏幕内；
- 只会使用屏幕的可视区域，不会压到菜单栏和 Dock；
- 该脚本已内嵌在 `Karabiner-Elements.json` 里，导入即可用（修改脚本时需要同步两处）；
- 首次使用需要授权：**系统设置 → 隐私与安全性 → 辅助功能**，打开 `karabiner_grabber`（必要时也加上 `osascript`）；
- 处于原生全屏状态的窗口因为 macOS 限制无法移动，这种情况会响一声提示音。


