-- CapsLock Pro: 把当前前台窗口移动到其他屏幕
-- 用法: osascript move-window-to-display.applescript [next|prev|1..9|fullscreen]
--   next  移动到下一个屏幕 (默认)
--   prev  移动到上一个屏幕
--   1..9  移动到指定序号的屏幕
--   fullscreen  切换当前窗口的原生全屏状态
--
-- 说明: 窗口移动时保持原尺寸；只有目标屏幕放不下时才等比缩小。
--       最大化或原生全屏窗口会在移动完成后恢复原状态。
--
-- 注意: 首次使用需要在 系统设置 -> 隐私与安全性 -> 辅助功能 中
--       允许 karabiner_grabber / osascript 控制电脑。
--       (本文件内容与 Karabiner-Elements.json 中内嵌的脚本保持一致,
--        修改时请同步两处)

use framework "Foundation"
use framework "AppKit"
use scripting additions

on run argv
    set arg to "next"
    if (count of argv) > 0 then set arg to item 1 of argv

    if arg is "fullscreen" then
        tell application "System Events"
            set ap to first application process whose frontmost is true
            set wl to every window of ap
            set w to missing value
            repeat with x in wl
                try
                    if (value of attribute "AXMain" of x) is true then
                        set w to contents of x
                        exit repeat
                    end if
                end try
            end repeat
            if w is missing value and (count of wl) > 0 then set w to item 1 of wl
            if w is missing value then return

            try
                set isFullScreen to (value of attribute "AXFullScreen" of w) is true
                set targetFullScreen to not isFullScreen
                set value of attribute "AXFullScreen" of w to targetFullScreen
            on error
                beep
            end try
        end tell
        return
    end if

    -- 1. 收集各屏幕的可视区域, 并转换为 AX 坐标系 (左上为原点, y 轴向下)
    -- NSScreen.mainScreen 会跟随当前键盘焦点窗口改变，不能用它作为全局坐标基准。
    set nsScreens to current application's NSScreen's screens()
    set primaryFrame to nsScreens's firstObject()'s frame()
    set primaryTop to (item 2 of (item 1 of primaryFrame)) + (item 2 of (item 2 of primaryFrame))
    set screenList to {}
    repeat with s in nsScreens
        set f to s's visibleFrame()
        set ox to item 1 of (item 1 of f)
        set oy to primaryTop - (item 2 of (item 1 of f)) - (item 2 of (item 2 of f))
        set sw to item 1 of (item 2 of f)
        set sh to item 2 of (item 2 of f)
        set end of screenList to {ox, oy, sw, sh}
    end repeat
    set n to count of screenList
    if n < 2 then return

    set movedOK to true
    tell application "System Events"
        -- 2. 取当前前台应用的窗口 (优先取主窗口)
        set ap to first application process whose frontmost is true
        set wl to every window of ap
        set w to missing value
        repeat with x in wl
            try
                if (value of attribute "AXMain" of x) is true then
                    set w to contents of x
                    exit repeat
                end if
            end try
        end repeat
        if w is missing value and (count of wl) > 0 then set w to item 1 of wl
        if w is missing value then return

        -- 3. 先在不改变窗口状态的情况下确定当前屏幕
        set winPos to position of w
        set winSize to size of w
        set wx to item 1 of winPos
        set wy to item 2 of winPos
        set ww to item 1 of winSize
        set wh to item 2 of winSize
        set cx to wx + ww / 2
        set cy to wy + wh / 2

        -- 判断窗口当前所在的屏幕 (按窗口中心点)
        set curIdx to 0
        repeat with i from 1 to n
            set sc to item i of screenList
            if cx >= (item 1 of sc) and cx < (item 1 of sc) + (item 3 of sc) and cy >= (item 2 of sc) and cy < (item 2 of sc) + (item 4 of sc) then
                set curIdx to i
                exit repeat
            end if
        end repeat
        if curIdx is 0 then
            -- 窗口中心不在任何屏幕内 (跨屏或部分在屏幕外), 取距离最近的屏幕
            set bestDist to -1
            repeat with i from 1 to n
                set sc to item i of screenList
                set dx to cx - ((item 1 of sc) + (item 3 of sc) / 2)
                set dy to cy - ((item 2 of sc) + (item 4 of sc) / 2)
                set d to dx * dx + dy * dy
                if bestDist < 0 or d < bestDist then
                    set bestDist to d
                    set curIdx to i
                end if
            end repeat
        end if

        -- 4. 计算目标屏幕。目标未变时直接返回，不触碰窗口状态。
        if arg is "next" then
            set tgtIdx to curIdx mod n + 1
        else if arg is "prev" then
            set tgtIdx to (curIdx + n - 2) mod n + 1
        else
            set tgtIdx to arg as integer
            if tgtIdx < 1 or tgtIdx > n then return
        end if
        if tgtIdx is curIdx then return

        -- 5. 最大化 / 原生全屏的窗口先还原，移动后再恢复状态
        set wasFullScreen to false
        try
            set wasFullScreen to (value of attribute "AXFullScreen" of w) is true
            if wasFullScreen then
                set value of attribute "AXFullScreen" of w to false
                delay 0.8
            end if
        end try
        set wasZoomed to false
        if not wasFullScreen then
            try
                set wasZoomed to zoomed of w
                if wasZoomed then
                    set zoomed of w to false
                    delay 0.3
                end if
            end try
        end if

        -- 还原后的位置和尺寸才是需要跨屏映射的普通窗口几何信息
        set winPos to position of w
        set winSize to size of w
        set wx to item 1 of winPos
        set wy to item 2 of winPos
        set ww to item 1 of winSize
        set wh to item 2 of winSize

        set src to item curIdx of screenList
        set dst to item tgtIdx of screenList

        -- 6. 保持窗口尺寸和相对位置；只有目标屏幕放不下时才等比缩小
        set srcAvailableW to (item 3 of src) - ww
        set srcAvailableH to (item 4 of src) - wh
        if srcAvailableW > 1 then
            set rx to (wx - (item 1 of src)) / srcAvailableW
        else
            set rx to 0.5
        end if
        if srcAvailableH > 1 then
            set ry to (wy - (item 2 of src)) / srcAvailableH
        else
            set ry to 0.5
        end if
        if rx < 0 then set rx to 0
        if rx > 1 then set rx to 1
        if ry < 0 then set ry to 0
        if ry > 1 then set ry to 1

        set fitScale to 1
        if ww > (item 3 of dst) then set fitScale to (item 3 of dst) / ww
        if wh * fitScale > (item 4 of dst) then set fitScale to (item 4 of dst) / wh
        set nw to ww * fitScale
        set nh to wh * fitScale

        -- 7. 先把窗口交给目标屏幕管理，避免 iTerm2 在源屏上按字符网格提前改小尺寸
        set transferW to ww
        if transferW > (item 3 of dst) then set transferW to item 3 of dst
        set transferH to wh
        if transferH > (item 4 of dst) then set transferH to item 4 of dst
        set tx to (item 1 of dst) + rx * ((item 3 of dst) - transferW)
        set ty to (item 2 of dst) + ry * ((item 4 of dst) - transferH)
        set position of w to {tx as integer, ty as integer}
        delay 0.15

        -- 尺寸未变时不要重写 AXSize，否则 iTerm2 会因字符网格发生不必要的缩放
        set transferredSize to size of w
        set transferredW to item 1 of transferredSize
        set transferredH to item 2 of transferredSize
        if (nw as integer) is not (transferredW as integer) or (nh as integer) is not (transferredH as integer) then
            set size of w to {nw as integer, nh as integer}
            delay 0.1
        end if
        set realSize to size of w
        set nw to item 1 of realSize
        set nh to item 2 of realSize
        set nx to (item 1 of dst) + rx * ((item 3 of dst) - nw)
        set ny to (item 2 of dst) + ry * ((item 4 of dst) - nh)
        -- 保证窗口完整落在目标屏幕内
        if nx < (item 1 of dst) then set nx to item 1 of dst
        if ny < (item 2 of dst) then set ny to item 2 of dst
        if nx + nw > (item 1 of dst) + (item 3 of dst) then set nx to (item 1 of dst) + (item 3 of dst) - nw
        if ny + nh > (item 2 of dst) + (item 4 of dst) then set ny to (item 2 of dst) + (item 4 of dst) - nh
        set nxi to nx as integer
        set nyi to ny as integer

        -- 8. 再移动窗口
        set position of w to {nxi, nyi}
        delay 0.2
        set newPos to position of w
        if (item 1 of newPos) is not nxi or (item 2 of newPos) is not nyi then set movedOK to false

        -- 无论移动是否成功都尽量恢复原状态，避免窗口被留在还原后的小尺寸。
        if wasZoomed then
            try
                set zoomed of w to true
                delay 0.2
            end try
        end if
        if wasFullScreen then
            try
                set value of attribute "AXFullScreen" of w to true
                delay 0.8
            end try
        end if
    end tell

    -- 窗口被原生全屏等状态挡住时会移动失败, 给一声提示
    if not movedOK then beep
end run
