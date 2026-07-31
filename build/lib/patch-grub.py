#!/usr/bin/env python3
"""
改写 live ISO 的 grub.cfg。

比 sed 靠谱的地方：删 menuentry 时按大括号配对整块删掉，不会删半截。

用法:
  patch-grub.py --cfg boot/grub/grub.cfg \
                --args "nouveau.modeset=0 consoleblank=0" \
                --title "KLBurn 出厂测试 v0.1.0" \
                --drop "HWE kernel" \
                --timeout 5
"""
import argparse
import re
import sys

MENUENTRY_RE = re.compile(r'^\s*(menuentry|submenu)\b')
LINUX_RE = re.compile(r'^(\s*linux(?:16|efi)?\s+/casper/\S+)(.*)$')
LAYERFS_RE = re.compile(r'\s*layerfs-path=\S+')


def drop_blocks(lines, pattern):
    """删掉标题匹配 pattern 的 menuentry 块（含嵌套大括号）。"""
    if not pattern:
        return lines, 0
    rx = re.compile(pattern)
    out, dropped, i = [], 0, 0
    while i < len(lines):
        line = lines[i]
        if MENUENTRY_RE.match(line) and rx.search(line):
            depth = line.count('{') - line.count('}')
            i += 1
            # menuentry 的 { 可能在下一行
            while i < len(lines) and depth <= 0:
                depth += lines[i].count('{') - lines[i].count('}')
                i += 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count('{') - lines[i].count('}')
                i += 1
            dropped += 1
            continue
        out.append(line)
        i += 1
    return out, dropped


def _strip_existing(text, extra_args):
    """把我们准备加的参数从原有命令行里摘干净，保证重复执行不会越加越长。"""
    for tok in extra_args.split():
        key = tok.split('=', 1)[0]
        if '=' in tok:
            # key=value 形式：不管原值是什么都摘掉
            text = re.sub(rf'(?<!\S){re.escape(key)}=\S*', '', text)
        else:
            text = re.sub(rf'(?<!\S){re.escape(tok)}(?!\S)', '', text)
    return text


def patch_kernel_args(lines, extra_args):
    """给每条 linux /casper/xxx 行加参数。幂等：先摘掉同名参数再追加。"""
    n = 0
    for idx, line in enumerate(lines):
        m = LINUX_RE.match(line)
        if not m:
            continue
        head, tail = m.group(1), m.group(2)
        tail = LAYERFS_RE.sub('', tail)
        tail = _strip_existing(tail, extra_args)
        # casper 用 --- 分隔内核参数和传给 live 系统的参数，我们的必须放 --- 前面
        if '---' in tail:
            before, _, after = tail.partition('---')
            parts = [extra_args, before.strip(), '---', after.strip()]
        else:
            parts = [extra_args, tail.strip()]
        tail = ' ' + ' '.join(p for p in parts if p)
        lines[idx] = head + tail.rstrip()
        n += 1
    return lines, n


def retitle_first(lines, title):
    for idx, line in enumerate(lines):
        if MENUENTRY_RE.match(line):
            lines[idx] = re.sub(
                r'''^(\s*menuentry\s+)(['"]).*?\2''',
                lambda mm: f'{mm.group(1)}"{title}"',
                line, count=1)
            return lines, True
    return lines, False


def set_global(lines, key, value):
    rx = re.compile(rf'^set\s+{key}=')
    for idx, line in enumerate(lines):
        if rx.match(line):
            lines[idx] = f'set {key}={value}'
            return lines
    # 没有就插到第一条 menuentry 之前
    for idx, line in enumerate(lines):
        if MENUENTRY_RE.match(line):
            lines.insert(idx, f'set {key}={value}')
            return lines
    lines.insert(0, f'set {key}={value}')
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cfg', required=True)
    ap.add_argument('--args', default='')
    ap.add_argument('--title', default='')
    ap.add_argument('--drop', default='')
    ap.add_argument('--timeout', default='5')
    a = ap.parse_args()

    try:
        with open(a.cfg, 'r', encoding='utf-8', errors='surrogateescape') as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        print(f'  patch-grub: {a.cfg} 不存在，跳过')
        return 0

    lines, dropped = drop_blocks(lines, a.drop)
    lines, npatched = patch_kernel_args(lines, a.args) if a.args else (lines, 0)
    lines = set_global(lines, 'timeout', a.timeout)
    lines = set_global(lines, 'default', '0')
    retitled = False
    if a.title:
        lines, retitled = retitle_first(lines, a.title)

    if npatched == 0 and a.args:
        print(f'  patch-grub: 警告 —— {a.cfg} 里没有匹配到 linux /casper/ 行',
              file=sys.stderr)

    with open(a.cfg, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write('\n'.join(lines) + '\n')

    print(f'  patch-grub: {a.cfg} -> 删除 {dropped} 个菜单项, '
          f'改写 {npatched} 条内核行, 改标题={retitled}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
