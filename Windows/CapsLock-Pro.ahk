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

CapsLock & f::  ; 按下 Ctrl+F 最大化当前激活窗口
{
    activeWindow := WinGetID("A")  ; 获取当前激活窗口的句柄
    if (activeWindow)  ; 如果成功获取到窗口句柄
    {
        WinMaximize(activeWindow)  ; 最大化窗口
    }
    else
    {
        MsgBox("未找到当前激活的窗口。")
    }
}


; 居中并恢复窗口
CapsLock & r:: {
    activeWindow := WinGetID("A")
    if (activeWindow) {
        ; 先恢复窗口（如果处于最大化状态）
        WinRestore(activeWindow)
        
        ; 获取显示器工作区尺寸（排除任务栏）
        monitorWorkArea := SysGet(16)  ; SM_CXVIRTUALSCREEN
        screenWidth := SysGet(16)
        screenHeight := SysGet(17)
        
        ; 获取窗口尺寸
        WinGetPos( , , &winWidth, &winHeight, activeWindow)
        
        ; 计算居中位置
        newX := (screenWidth - winWidth) // 2
        newY := (screenHeight - winHeight) // 2
        
        ; 移动窗口到中心位置
        WinMove(newX, newY, winWidth, winHeight, activeWindow)
    } else {
        MsgBox("未找到当前激活的窗口。")
    }
}
