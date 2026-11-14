#!/usr/bin/env python3
"""Builds the installable plugin: python tools/build-release.py <version>

Writes dist/CastNowPlaying-<version>.zip (the folder layout LMS expects: CastNowPlaying/...)
and rewrites repo.xml at the repo root with the new version, download URL and SHA-1.
repo.xml is served by GitHub Pages; LMS users add its URL under Settings > Plugins.
"""
import hashlib
import pathlib
import re
import sys
import zipfile
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = ROOT / 'src' / 'CastNowPlaying'
NAME = 'CastNowPlaying'
GITHUB = 'https://github.com/nas963/lyrion-cast-nowplaying'
TEXT_SUFFIXES = {'.pm', '.txt', '.html', '.js', '.xml', '.css', '.md'}


def strings(key):
    """EN and SR text of one key from strings.txt."""
    out, cur = {}, None
    for line in (PLUGIN / 'strings.txt').read_text(encoding='utf-8').splitlines():
        if line and not line[0].isspace():
            cur = line.strip()
        elif cur == key and line.strip():
            lang, text = line.strip().split('\t', 1) if '\t' in line.strip() else line.strip().split(None, 1)
            out[lang] = text.strip()
    return out


def add(out, name, data):
    info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    out.writestr(info, data)


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r'\d+\.\d+\.\d+', sys.argv[1]):
        raise SystemExit(__doc__)
    version = sys.argv[1]
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    target = dist / f'{NAME}-{version}.zip'

    found = False
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as out:
        for path in sorted(PLUGIN.rglob('*')):
            if path.is_dir():
                continue
            data = path.read_bytes()
            if path.suffix in TEXT_SUFFIXES and b'\r' in data:
                raise SystemExit(f'CRLF in {path}')
            if path.name == 'install.xml' and path.parent == PLUGIN:
                data, n = re.subn(rb'<version>[^<]*</version>', f'<version>{version}</version>'.encode(), data)
                if n != 1:
                    raise SystemExit('install.xml: expected exactly one <version>')
                found = True
            add(out, f'{NAME}/{path.relative_to(PLUGIN).as_posix()}', data)
        add(out, f'{NAME}/LICENSE', (ROOT / 'LICENSE').read_bytes())
    if not found:
        raise SystemExit('src/CastNowPlaying/install.xml missing')

    sha1 = hashlib.sha1(target.read_bytes()).hexdigest()
    title, desc = strings('PLUGIN_CASTNOWPLAYING'), strings('PLUGIN_CASTNOWPLAYING_DESC')
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<extensions>',
        '  <details>',
        '    <title lang="EN">Cast Now Playing</title>',
        '  </details>',
        '  <plugins>',
        f'    <plugin name="{NAME}" version="{version}" minTarget="8.0" maxTarget="*">',
    ]
    lines += [f'      <title lang="{l}">{escape(t)}</title>' for l, t in title.items()]
    lines += [f'      <desc lang="{l}">{escape(t)}</desc>' for l, t in desc.items()]
    lines += [
        '      <creator>nas963</creator>',
        '      <category>information</category>',
        f'      <link>{GITHUB}</link>',
        f'      <url>{GITHUB}/releases/download/v{version}/{target.name}</url>',
        f'      <sha>{sha1}</sha>',
        '    </plugin>',
        '  </plugins>',
        '</extensions>',
        '',
    ]
    (ROOT / 'repo.xml').write_bytes('\n'.join(lines).encode('utf-8'))
    print(f'{target}  sha1 {sha1}')


if __name__ == '__main__':
    main()
