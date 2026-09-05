#!/bin/bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
swift_source="$script_dir/src/move-window-display.swift"
rules_source="$script_dir/Karabiner-Elements.json"

bin_dir="${CAPSLOCK_PRO_BIN_DIR:-$HOME/.local/bin}"
karabiner_config="${CAPSLOCK_PRO_KARABINER_CONFIG:-$HOME/.config/karabiner/karabiner.json}"
assets_dir="${CAPSLOCK_PRO_KARABINER_ASSETS_DIR:-$HOME/.config/karabiner/assets/complex_modifications}"
binary_path="$bin_dir/move-window-display"
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

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/capslock-pro.XXXXXX")"
temporary_binary="$temporary_directory/move-window-display"
cleanup() {
    rm -f "$temporary_binary"
    rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$force_rebuild" = true ] || [ ! -x "$binary_path" ] || [ "$swift_source" -nt "$binary_path" ]; then
    printf '正在编译 Swift 工具……\n'
    # 保持输出文件名固定，避免链接器生成随机的代码签名标识。
    swiftc -O "$swift_source" -o "$temporary_binary"
    install -m 0755 "$temporary_binary" "$binary_path"
else
    printf 'Swift 工具已经是最新版本，跳过编译。\n'
fi

rules_title="$(/usr/bin/plutil -extract title raw -o - "$rules_source")"
asset_path="$assets_dir/capslock-pro.json"
for candidate in "$assets_dir"/*.json; do
    [ -f "$candidate" ] || continue
    candidate_title="$(/usr/bin/plutil -extract title raw -o - "$candidate" 2>/dev/null || true)"
    if [ "$candidate_title" = "$rules_title" ]; then
        asset_path="$candidate"
        break
    fi
done

config_mode="$(stat -f '%Lp' "$karabiner_config")"
config_backup="$karabiner_config.capslock-pro.backup"
cp -p "$karabiner_config" "$config_backup"

printf '正在更新 Karabiner 当前 profile……\n'
sync_result="$(/usr/bin/osascript -l JavaScript - \
    "$rules_source" "$asset_path" "$karabiner_config" <<'JXA'
ObjC.import('Foundation');

function readText(path) {
    const value = $.NSString.stringWithContentsOfFileEncodingError(
        path,
        $.NSUTF8StringEncoding,
        null
    );
    if (!value) {
        throw new Error('无法读取文件：' + path);
    }
    return ObjC.unwrap(value);
}

function readJSON(path) {
    return JSON.parse(readText(path));
}

function writeTextAtomically(path, contents) {
    const written = $(contents).writeToFileAtomicallyEncodingError(
        path,
        true,
        $.NSUTF8StringEncoding,
        null
    );
    if (!written) {
        throw new Error('无法写入文件：' + path);
    }
}

function descriptionsFrom(rules) {
    return (rules || [])
        .map(function (rule) { return rule.description; })
        .filter(function (description) { return typeof description === 'string'; });
}

function run(argv) {
    const sourcePath = argv[0];
    const installedAssetPath = argv[1];
    const configPath = argv[2];
    const source = readJSON(sourcePath);
    const configText = readText(configPath);
    const config = JSON.parse(configText);

    let previousRules = [];
    try {
        const previousAsset = readJSON(installedAssetPath);
        if (previousAsset.title === source.title) {
            previousRules = previousAsset.rules || [];
        }
    } catch (_) {
        // 第一次安装时资源文件尚不存在。
    }

    const managedDescriptions = new Set(
        descriptionsFrom(source.rules).concat(descriptionsFrom(previousRules), [
            // 即使旧资源文件已被删除，也要替换会在单按时开启大写的旧规则。
            'CAPSLOCK + hjkl to arrow keys (Post CAPSLOCK if press CAPSLOCK alone)'
        ])
    );
    const selectedProfiles = (config.profiles || []).filter(function (profile) {
        return profile.selected === true;
    });
    if (selectedProfiles.length === 0) {
        throw new Error('Karabiner 配置中没有当前选中的 profile');
    }

    selectedProfiles.forEach(function (profile) {
        if (!profile.complex_modifications) {
            profile.complex_modifications = {};
        }
        const existingRules = profile.complex_modifications.rules || [];
        const firstManagedIndex = existingRules.findIndex(function (rule) {
            return managedDescriptions.has(rule.description);
        });
        const insertAt = firstManagedIndex < 0
            ? existingRules.length
            : existingRules.slice(0, firstManagedIndex).filter(function (rule) {
                return !managedDescriptions.has(rule.description);
            }).length;
        const unmanagedRules = existingRules.filter(function (rule) {
            return !managedDescriptions.has(rule.description);
        });
        const replacementRules = JSON.parse(JSON.stringify(source.rules || []));
        unmanagedRules.splice.apply(
            unmanagedRules,
            [insertAt, 0].concat(replacementRules)
        );
        profile.complex_modifications.rules = unmanagedRules;
    });

    const updatedText = JSON.stringify(config, null, 4) + '\n';
    if (updatedText !== configText) {
        writeTextAtomically(configPath, updatedText);
        return 'updated';
    }
    return 'unchanged';
}
JXA
)"
chmod "$config_mode" "$karabiner_config"
install -m 0644 "$rules_source" "$asset_path"

if [ "$sync_result" = "updated" ]; then
    printf 'Karabiner 配置已更新。\n'
else
    printf 'Karabiner 配置已经是最新版本。\n'
fi
printf 'Swift 可执行文件：%s\n' "$binary_path"
printf 'Karabiner 规则资源：%s\n' "$asset_path"
printf '配置备份：%s\n' "$config_backup"
