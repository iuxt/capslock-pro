#!/bin/bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
rules_source="$script_dir/Karabiner-Elements.json"

bin_dir="${CAPSLOCK_PRO_BIN_DIR:-$HOME/.local/bin}"
karabiner_config="${CAPSLOCK_PRO_KARABINER_CONFIG:-$HOME/.config/karabiner/karabiner.json}"
assets_dir="${CAPSLOCK_PRO_KARABINER_ASSETS_DIR:-$HOME/.config/karabiner/assets/complex_modifications}"
launch_agents_dir="${CAPSLOCK_PRO_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
agent_label="local.capslock-pro.brightness-restore"
force_rebuild=false

if [ "${1:-}" = "--force" ]; then
    force_rebuild=true
    shift
fi
if [ "$#" -ne 0 ]; then
    printf '用法：%s [--force]\n' "$0" >&2
    exit 2
fi

if [ "$(uname -s)" != "Darwin" ]; then
    printf '错误：此脚本只能在 macOS 上运行。\n' >&2
    exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
    printf '错误：找不到 swiftc，请先运行 xcode-select --install。\n' >&2
    exit 1
fi

if [ ! -f "$karabiner_config" ]; then
    printf '错误：找不到 Karabiner 配置：%s\n' "$karabiner_config" >&2
    printf '请先启动一次 Karabiner-Elements，再重新运行此脚本。\n' >&2
    exit 1
fi

mkdir -p "$bin_dir" "$assets_dir"
# Karabiner 的工作目录与安装脚本不同，规则中必须使用绝对路径。
bin_dir="$(CDPATH= cd -- "$bin_dir" && pwd)"
binary_path="$bin_dir/move-window-display"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/capslock-pro.XXXXXX")"
temporary_binary="$temporary_directory/move-window-display"
brightness_path="$bin_dir/display-brightness"
cleanup() {
    rm -f "$temporary_directory/move-window-display" "$temporary_directory/display-brightness"
    rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT

# 升级旧版：先卸载已注册的任务，再清理它独有的文件；不碰手动调节和浮层的缓存。
service="gui/$(id -u)/$agent_label"
if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service"
fi
rm -f "$launch_agents_dir/$agent_label.plist" "$HOME/Library/Caches/CapsLock-Pro/brightness-watcher.lock"
preferences="$HOME/Library/Application Support/CapsLock-Pro/Brightness"
if [ -d "$preferences" ] && [ ! -L "$preferences" ]; then
    uuid_file='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}\.json$'
    for record in "$preferences"/*.json; do
        if [ -f "$record" ] && [[ "${record##*/}" =~ $uuid_file ]]; then
            rm -f "$record"
        fi
    done
    rmdir "$preferences" 2>/dev/null || true
fi

for tool_name in move-window-display display-brightness; do
    swift_source="$script_dir/src/$tool_name.swift"
    tool_path="$bin_dir/$tool_name"
    temporary_binary="$temporary_directory/$tool_name"
    if [ "$force_rebuild" = true ] || [ ! -x "$tool_path" ] || [ "$swift_source" -nt "$tool_path" ]; then
        printf '正在编译 Swift 工具 %s……\n' "$tool_name"
        # 保持输出文件名固定，避免链接器生成随机的代码签名标识。
        swiftc -O "$swift_source" -o "$temporary_binary"
        install -m 0755 "$temporary_binary" "$tool_path"
    else
        printf 'Swift 工具 %s 已经是最新版本，跳过编译。\n' "$tool_name"
    fi
done

printf '正在更新 Karabiner 当前 profile……\n'
/usr/bin/python3 "$script_dir/sync_rules.py" "$rules_source" "$assets_dir" "$karabiner_config" \
    "$bin_dir"

printf 'Swift 可执行文件：%s\n' "$binary_path"
printf '亮度可执行文件：%s\n' "$brightness_path"
printf '配置备份：%s\n' "$karabiner_config.capslock-pro.backup"
