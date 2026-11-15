"""Sync CapsLock Pro into the active Karabiner profile without reformatting user settings."""
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

# Mask comments, never quoted strings. Offsets in the masked and original text stay identical.
JSONC = re.compile(r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/')
DECODER = json.JSONDecoder()
SPACE = re.compile(r'[ \t\r\n]*')
ALIASES = {
    'CAPSLOCK + hjkl to arrow keys (Post CAPSLOCK if press CAPSLOCK alone)':
        'CAPSLOCK + hjkl to arrow keys, CAPSLOCK + Esc to toggle Caps Lock',
    'CAPSLOCK + [ / ] to decrease / increase external display hardware brightness':
        'CAPSLOCK + F1 / F2 to decrease / increase external display hardware brightness',
}


def mask(text):
    return JSONC.sub(lambda m: m[0] if m[0][0] == '"' else ' ' * len(m[0]), text)


def members(text, start):
    """Index immediate members of a validated, comment-masked object or array."""
    pos = SPACE.match(text, start + 1).end()
    index = {}
    while text[pos] not in ']}':
        key = len(index)
        if text[start] == '{':
            key, pos = DECODER.raw_decode(text, pos)
            pos = SPACE.match(text, SPACE.match(text, pos).end() + 1).end()
        _, end = DECODER.raw_decode(text, pos)
        index[key] = (pos, end)
        pos = SPACE.match(text, end).end()
        if text[pos] == ',':
            pos = SPACE.match(text, pos + 1).end()
    return index


def serialize(obj, indent):
    return json.dumps(obj, indent=4, ensure_ascii=False).replace('\n', '\n' + indent)


def update_profile(original, rules, previous):
    clean = mask(original)
    config = json.loads(clean)
    profiles = config.get('profiles', [])
    if not profiles:
        raise ValueError('Karabiner 配置中没有 profile')
    active = next((i for i, p in enumerate(profiles) if p.get('selected') is True), 0)
    start = members(clean, SPACE.match(clean).end())['profiles'][0]
    start = members(clean, start)[active][0]
    existing = profiles[active]
    for key in ('complex_modifications', 'rules'):
        fields = members(clean, start)
        if key not in fields:
            # Insert immediately after the opening brace, leaving all existing text intact.
            indent = re.match(r'[ \t]*', original[original.rfind('\n', 0, start) + 1:])[0] + '    '
            value = {'rules': rules} if key == 'complex_modifications' else rules
            added = '\n' + indent + json.dumps(key) + ': ' + serialize(value, indent)
            return original[:start + 1] + added + (',' if fields else '\n' + indent[:-4]) + original[start + 1:]
        start, end = fields[key]
        existing = existing[key]

    if not isinstance(existing, list):
        raise ValueError('complex_modifications.rules 不是数组')
    by_name = {r['description']: r for r in rules}
    remaining = dict(by_name)
    retired = {r.get('description') for r in previous if r.get('description')}
    spans = members(clean, start)
    chunks = []
    changed = False
    left = start + 1
    base_indent = re.match(r'[ \t]*', original[original.rfind('\n', 0, start) + 1:])[0]
    for i, old in enumerate(existing):
        a, b = spans[i]
        right = SPACE.match(clean, b).end()  # comma or closing bracket
        name = old.get('description')
        name = ALIASES.get(name, name)
        fragment = original[a:b]
        if name in remaining:
            replacement = dict(remaining.pop(name))
            if 'enabled' in old:
                replacement['enabled'] = old['enabled']
            if old != replacement:
                fragment = serialize(replacement, base_indent + '    ')
                changed = True
        elif name in by_name or name in retired:
            changed = True  # duplicate or obsolete project rule
            left = right + 1
            continue
        chunks.append(original[left:a] + fragment + original[b:right])
        left = right + 1

    if not changed and not remaining:
        return original
    if not existing:
        chunks_prefix = original[start + 1:end - 1]  # comments inside an empty array
    else:
        chunks_prefix = ''
    for rule in remaining.values():
        chunks.append('\n' + base_indent + '    ' + serialize(rule, base_indent + '    '))
    return original[:start + 1] + chunks_prefix + ','.join(chunks) + '\n' + base_indent + original[end - 1:]


def atomic_write(path, data, mode, exclusive=False):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        tmp = Path(f.name)
    try:
        tmp.write_bytes(data)
        tmp.chmod(mode)
        if exclusive:
            os.link(tmp, path)  # Never replace a file even if another installer won the race.
        else:
            os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def sync(source_path, assets, config, bin_dir):
    source = json.loads(source_path.read_bytes())
    previous = []
    asset = None
    for path in sorted(assets.glob('*.json')):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            old = json.loads(mask(path.read_text(encoding='utf-8')))
        except (ValueError, UnicodeError):
            continue
        if isinstance(old, dict) and old.get('title') == source['title']:
            asset, previous = path, old.get('rules', [])
            break
    for rule in source['rules']:
        for m in rule['manipulators']:
            for event in m.get('to', []):
                for tool in ('move-window-display', 'display-brightness'):
                    prefix = '"$HOME/.local/bin/' + tool + '" '
                    command = event.get('shell_command', '')
                    if command.startswith(prefix):
                        quoted = "'" + str(bin_dir / tool).replace("'", "'\\''") + "'"
                        event['shell_command'] = quoted + ' ' + command[len(prefix):]

    data = config.read_bytes()
    original = data.decode('utf-8')
    updated = update_profile(original, source['rules'], previous)
    rendered = (json.dumps(source, indent=4, ensure_ascii=False) + '\n').encode()
    if asset is None:
        index = 1
        while True:
            suffix = '' if index == 1 else '-' + str(index)
            asset = assets / ('capslock-pro' + suffix + '.json')
            try:
                atomic_write(asset, rendered, 0o644, exclusive=True)
                break
            except FileExistsError:
                index += 1
    if updated != original:
        if config.read_bytes() != data:
            raise ValueError('Karabiner 配置已被其他程序修改，请重试')
        mode = stat.S_IMODE(config.stat().st_mode)
        atomic_write(Path(str(config) + '.capslock-pro.backup'), data, mode)
        atomic_write(config, updated.encode(), mode)
        print('Karabiner 配置已更新。')
    else:
        print('Karabiner 配置已经是最新版本。')
    if asset.read_bytes() != rendered:
        atomic_write(asset, rendered, 0o644)
    print('Karabiner 规则资源：' + str(asset))


if __name__ == '__main__':
    sync(*map(Path, sys.argv[1:]))
