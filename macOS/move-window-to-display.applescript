-- CapsLock Pro: 把当前前台窗口移动到其他屏幕
-- 用法: osascript move-window-to-display.applescript [next|prev|1..9]
--   next  移动到下一个屏幕 (默认)
--   prev  移动到上一个屏幕
--   1..9  移动到指定序号的屏幕
--
-- 说明: 窗口按等比缩放到目标屏幕, 并尽量保持原来的相对位置。
--       处于原生全屏状态的窗口无法移动 (macOS 限制), 会发出一声提示音。
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

    -- 1. 收集各屏幕的可视区域, 并转换为 AX 坐标系 (左上为原点, y 轴向下)
    set mainH to item 2 of (item 2 of (current application's NSScreen's mainScreen()'s frame()))
    set screenList to {}
    repeat with s in (current application's NSScreen's screens())
        set f to s's visibleFrame()
        set ox to item 1 of (item 1 of f)
        set oy to mainH - (item 2 of (item 1 of f)) - (item 2 of (item 2 of f))
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

        -- 3. 最大化 / 原生全屏的窗口无法移动, 先尝试还原
        try
            if zoomed of w then
                set zoomed of w to false
                delay 0.3
            end if
        end try
        try
            if (value of attribute "AXFullScreen" of w) is true then
                set value of attribute "AXFullScreen" of w to false
                delay 0.8
            end if
        end try

        set winPos to position of w
        set winSize to size of w
        set wx to item 1 of winPos
        set wy to item 2 of winPos
        set ww to item 1 of winSize
        set wh to item 2 of winSize
        set cx to wx + ww / 2
        set cy to wy + wh / 2

        -- 4. 判断窗口当前所在的屏幕 (按窗口中心点)
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

        -- 5. 计算目标屏幕
        if arg is "next" then
            set tgtIdx to curIdx mod n + 1
        else if arg is "prev" then
            set tgtIdx to (curIdx + n - 2) mod n + 1
        else
            set tgtIdx to arg as integer
            if tgtIdx < 1 or tgtIdx > n then return
        end if
        if tgtIdx is curIdx then return

        set src to item curIdx of screenList
        set dst to item tgtIdx of screenList

        -- 6. 按两个屏幕的分辨率差缩放, 保持窗口自身的宽高比, 避免被拉伸
        --    两个屏幕宽高比不同时取较小的缩放比 (完整放下)
        set rx to (wx - (item 1 of src)) / (item 3 of src)
        set ry to (wy - (item 2 of src)) / (item 4 of src)
        -- 按两个屏幕的面积比开方缩放, 窗口不会被拉伸变形, 且来回移动后尺寸能还原
        set rf to (((item 3 of dst) * (item 4 of dst)) / ((item 3 of src) * (item 4 of src))) ^ 0.5
        -- 贴满源屏幕的方向, 到目标屏幕继续贴满
        if ww >= (item 3 of src) * 0.95 then
            set nw to item 3 of dst
        else
            set nw to ww * rf
        end if
        if wh >= (item 4 of src) * 0.95 then
            set nh to item 4 of dst
        else
            set nh to wh * rf
        end if
        -- 窗口过小时放大到目标屏幕宽度的 20%, 并保持宽高比
        if nw < (item 3 of dst) * 0.2 then
            set k to ((item 3 of dst) * 0.2) / nw
            set nw to nw * k
            set nh to nh * k
        end if
        -- 收敛: 保持宽高比, 确保不超出目标屏幕 (含浮点误差)
        if nw > (item 3 of dst) then
            set k to (item 3 of dst) / nw
            set nw to nw * k
            set nh to nh * k
        end if
        if nh > (item 4 of dst) then
            set k to (item 4 of dst) / nh
            set nw to nw * k
            set nh to nh * k
        end if

        -- 7. 先改尺寸: 应用可能有自己的最小/最大尺寸, 所以按实际生效的尺寸再算位置
        set size of w to {nw as integer, nh as integer}
        delay 0.1
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
    end tell

    -- 窗口被原生全屏等状态挡住时会移动失败, 给一声提示
    if not movedOK then beep
end run
