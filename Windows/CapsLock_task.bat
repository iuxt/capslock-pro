@echo off
chcp 65001
%1 mshta vbscript:CreateObject("Shell.Application").ShellExecute("cmd.exe","/c %~s0 ::","","runas",1)(window.close)&&exit
cd /d "%~dp0"


:: 清除旧任务（可选）
schtasks /delete /f /tn "CapsLock Auto Run"

:: 创建任务（关键点解析见下文）
schtasks /create /tn "CapsLock Auto Run" /tr "C:\Users\iuxt\cosmos\windows\CapsLock-Pro\CapsLock-Pro.ahk" /sc onlogon /ru iuxt /rl highest /it /v1
