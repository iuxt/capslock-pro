; | !  |   alt             |
; | #  |   windows键       |
; | <# |   左边的windows键 |
; | ># |   右边的windows键 |
; | ^  |   Ctrl            |
; | +  |   Shift           |

CapsLock::Return  ; 禁用 CapsLock 默认行为
#SingleInstance force
SetCapsLockState "AlwaysOff"

; 管理员权限运行
full_command_line := DllCall("GetCommandLine", "str")

if not (A_IsAdmin or RegExMatch(full_command_line, " /restart(?!\S)"))
{
    try
    {
        if A_IsCompiled
            Run '*RunAs "' A_ScriptFullPath '" /restart'
        else
            Run '*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"'
    }
    ExitApp
}


tip(message, time := 5000) { ; 默认显示 5 秒
    ToolTip message
    SetTimer () => ToolTip(), -time ; 确保 time 为负值，以执行一次性定时器
}


; f5 重载配置
CapsLock & F5:: {
    tip("重载配置中...")
    Sleep 1000
    reload
}

; 切换CapsLock状态
CapsLock & Esc:: {
    static Toggle := false  ; 静态变量，初始值为 false
    Toggle := !Toggle        ; 切换状态
    SetCapsLockState (Toggle ? "AlwaysOn" : "AlwaysOff")
}


; 使用windows terminal
CapsLock & t::
{
    if WinExist("ahk_exe WindowsTerminal.exe")
        WinActivate
    else
        Run "terminal.bat"
}

; 方向
CapsLock & h::Send("{Left}")
CapsLock & l::Send("{Right}")
CapsLock & j::Send("{Down}")
CapsLock & k::Send("{Up}")

CapsLock & u:: {
    Send "{Home}"
}

CapsLock & i:: {
    Send "{End}"
}

; 新建一行，光标移到下一行
CapsLock & o:: {
    Send "{End}"
    Send "{Enter}"
}

; 切换到另一个显示器
CapsLock & d:: {
    Send "#+{Left}"
}

; bing搜索博客
CapsLock & s:: Run "https://cn.bing.com/search?q=site:zahui.fan"

CapsLock & f::  ; 切换当前激活窗口的最大化状态
{
    activeWindow := WinGetID("A")  ; 获取当前激活窗口的句柄
    if (activeWindow)  ; 如果成功获取到窗口句柄
    {
        if (WinGetMinMax(activeWindow) = 1)
            WinRestore(activeWindow)
        else
            WinMaximize(activeWindow)
    }
    else
    {
        MsgBox("未找到当前激活的窗口。")
    }
}


; 在当前显示器工作区的 80% 和 50% 两档大小之间切换，并居中
CapsLock & r:: {
    activeWindow := WinGetID("A")
    if (activeWindow) {
        ; 先用窗口中心点确定它所在的显示器。
        WinGetPos(&winX, &winY, &winWidth, &winHeight, activeWindow)
        centerX := winX + winWidth / 2
        centerY := winY + winHeight / 2
        monitorIndex := MonitorGetPrimary()
        bestDistance := ""

        Loop MonitorGetCount() {
            MonitorGet(A_Index, &monitorLeft, &monitorTop, &monitorRight, &monitorBottom)
            if (centerX >= monitorLeft && centerX < monitorRight
                && centerY >= monitorTop && centerY < monitorBottom) {
                monitorIndex := A_Index
                break
            }

            nearestX := Min(Max(centerX, monitorLeft), monitorRight)
            nearestY := Min(Max(centerY, monitorTop), monitorBottom)
            distance := (centerX - nearestX) ** 2 + (centerY - nearestY) ** 2
            if (bestDistance = "" || distance < bestDistance) {
                bestDistance := distance
                monitorIndex := A_Index
            }
        }

        ; 使用工作区而不是显示器完整尺寸，避开任务栏。
        MonitorGetWorkArea(monitorIndex, &workLeft, &workTop, &workRight, &workBottom)
        workWidth := workRight - workLeft
        workHeight := workBottom - workTop
        widthRatio := winWidth / workWidth
        heightRatio := winHeight / workHeight
        distanceFromLarge := Abs(widthRatio - 0.80) + Abs(heightRatio - 0.80)
        distanceFromSmall := Abs(widthRatio - 0.50) + Abs(heightRatio - 0.50)
        targetRatio := distanceFromLarge <= distanceFromSmall ? 0.50 : 0.80

        ; 最大化窗口需要先恢复，之后才能指定尺寸和位置。
        WinRestore(activeWindow)
        Sleep 100

        targetWidth := Round(workWidth * targetRatio)
        targetHeight := Round(workHeight * targetRatio)
        newX := Round(workLeft + (workWidth - targetWidth) / 2)
        newY := Round(workTop + (workHeight - targetHeight) / 2)
        WinMove(newX, newY, targetWidth, targetHeight, activeWindow)
    } else {
        MsgBox("未找到当前激活的窗口。")
    }
}
