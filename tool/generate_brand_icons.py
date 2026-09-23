"""Rasterize the approved, font-free brand SVGs for native desktop assets.

Requires Python 3 and librsvg's rsvg-convert on PATH. Normal application builds
use the checked-in output and do not run this generator or read another repo.
Run from any directory; --check renders in memory and rejects stale output.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
BRAND = Path('assets/brand')
MAC = Path('macos/Runner/Assets.xcassets')
WINDOWS = Path('windows/runner/resources')
APP_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
TRAY_SIZES = (16, 20, 24, 32, 40, 48, 64)
MAC_APP_SIZES = (16, 32, 64, 128, 256, 512, 1024)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def icon_container(images):
    """Windows Vista+ ICO directory with complete PNG payloads at each size."""
    offset = 6 + 16 * len(images)
    entries, payload = [], []
    for size, png in images.items():
        if not 1 <= size <= 256:
            raise ValueError('ICO dimensions must be at most 256')
        entries.append(struct.pack(
            '<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(png), offset,
        ))
        payload.append(png)
        offset += len(png)
    return struct.pack('<HHH', 0, 1, len(images)) + b''.join(entries + payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    renderer = shutil.which('rsvg-convert')
    if renderer is None:
        parser.exit(1, 'Install librsvg with rsvg-convert to regenerate icons.\n')
    renderer_version = subprocess.check_output(
        [renderer, '--version'], text=True,
    ).strip()
    sources = {}
    outputs = {}

    def render(name, size):
        source = BRAND / name
        svg = (ROOT / source).read_bytes()
        tree = ET.fromstring(svg)
        if any(element.tag.rsplit('}', 1)[-1] == 'text' for element in tree.iter()):
            raise ValueError(f'{source} contains text: icon generation needs outlines')
        sources[source.as_posix()] = sha256(svg)
        png = subprocess.check_output([
            renderer, '--width', str(size), '--height', str(size),
            str(ROOT / source),
        ])
        if png[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', png[16:24]) != (size, size):
            raise ValueError(f'Unexpected PNG output for {source} at {size}')
        return png

    app_images = {
        size: render('appicon-light.svg', size)
        for size in sorted(set(APP_SIZES) | set(MAC_APP_SIZES))
    }
    for size in MAC_APP_SIZES:
        outputs[MAC / 'AppIcon.appiconset' / f'app_icon_{size}.png'] = app_images[size]
    outputs[WINDOWS / 'app_icon.ico'] = icon_container({
        size: app_images[size] for size in APP_SIZES
    })

    for mode in ('ink', 'white'):
        images = {size: render(f'logo-mono-{mode}.svg', size) for size in TRAY_SIZES}
        outputs[WINDOWS / f'tray_{mode}.ico'] = icon_container(images)
        if mode == 'ink':
            # Template rendering makes AppKit choose contrast for the menu bar;
            # the two PNGs provide actual 16 pt @1x / @2x bitmap representations.
            catalog = MAC / 'TrayIcon.imageset'
            outputs[catalog / 'tray_icon_16.png'] = images[16]
            outputs[catalog / 'tray_icon_32.png'] = images[32]
            outputs[catalog / 'Contents.json'] = (json.dumps({
                'images': [
                    {'filename': f'tray_icon_{size}.png', 'idiom': 'mac', 'scale': scale}
                    for size, scale in ((16, '1x'), (32, '2x'))
                ],
                'info': {'author': 'xcode', 'version': 1},
                'properties': {'template-rendering-intent': 'template'},
            }, indent=2) + '\n').encode()

    manifest = {
        'renderer': renderer_version,
        'sources': sources,
        'outputs': {path.as_posix(): sha256(data) for path, data in outputs.items()},
    }
    outputs[BRAND / 'native-icons.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    changed = [path for path, data in outputs.items()
               if not (ROOT / path).exists() or (ROOT / path).read_bytes() != data]
    if args.check:
        if changed:
            parser.exit(1, 'Native icons are stale:\n' + '\n'.join(map(str, changed)) + '\n')
        print(f'{len(outputs)} native icon artifacts match the product SVG sources.')
    else:
        for path, data in outputs.items():
            (ROOT / path).parent.mkdir(parents=True, exist_ok=True)
            (ROOT / path).write_bytes(data)
        print(f'Generated {len(outputs)} native icon artifacts using {renderer_version}.')


if __name__ == '__main__':
    main()
