"""Generate Flutter values from the product-owned token snapshot.

Run python3 tool/generate_field_tokens.py, or append --check for a read-only
drift check. Uses only Python's standard library and files in this repository.
"""

import argparse
import json
from pathlib import Path


def dart_string(value):
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$') + "'"


def generate(data):
    lines = [
        '// Generated from assets/design/design-tokens.json. Do not edit values by hand.',
        "import 'package:flutter/material.dart';",
        '',
        'abstract final class FieldTokens {',
    ]
    for key, value in data['color'].items():
        lines.append(f"  static const {key} = Color(0xFF{value['value'][1:]});")
    for key, value in data['radius'].items():
        lines.append(f'  static const {key}Radius = {float(value)};')
    for key in ['body', 'mono']:
        font = data['font'][key]
        lines.append(f"  static const {key}FontFamily = {dart_string(font['family'])};")
        lines.append(f'  static const {key}FontFallback = <String>[')
        lines.extend(f'    {dart_string(family)},' for family in font['fallback'])
        lines.append('  ];')
    for key, value in data['typography'].items():
        lines.extend([
            f'  static const {key}Style = TextStyle(',
            f"    fontSize: {float(value['size'])},",
            f"    height: {value['lineHeight'] / value['size']},",
            f"    fontWeight: FontWeight.w{value['weight']},",
        ])
        if key == 'code':
            lines.extend([
                '    fontFamily: monoFontFamily,',
                '    fontFamilyFallback: monoFontFallback,',
            ])
        lines.append('  );')
    lines.append(f"  static const spaceUnit = {float(data['space']['unit'])};")
    for value in data['space']['scale']:
        lines.append(f'  static const space{value} = {float(value)};')
    node = data['component']['desktopNode']
    for key, value in {
        'nodeWidth': node['baseWidth'],
        'nodePadding': node['padding'],
        'touchTargetMin': data['component']['touchTargetMin'],
        'toolbarTarget': data['component']['toolbarTarget'],
        'focusWidth': data['component']['focusWidth'],
        'focusOffset': data['component']['focusOffset'],
    }.items():
        lines.append(f'  static const {key} = {float(value)};')
    lines.append(
        f"  static const holdDuration = Duration(milliseconds: {data['motion']['holdShortcut']['durationMs']});"
    )
    roles = [key for key in data['theme']['light'] if key != 'weakText']
    for mode in ['light', 'dark']:
        lines.append(f'  static const {mode}Theme = FieldThemeColors(')
        for role, reference in data['theme'][mode].items():
            if reference not in data['color']:
                raise ValueError(f'Unknown color token: {mode}.{role}={reference}')
            lines.append(f'    {role}: {reference},')
        lines.append('  );')
    lines.extend([
        '}',
        '',
        '/// Only roles explicitly supplied by the design palette are represented.',
        'class FieldThemeColors {',
        '  const FieldThemeColors({',
        *[f'    required this.{role},' for role in roles],
        '    this.weakText,',
        '  });',
        *[f'  final Color {role};' for role in roles],
        '  final Color? weakText;',
        '}',
    ])
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if generated Dart differs')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    data = json.loads((root / 'assets/design/design-tokens.json').read_text(encoding='utf-8'))
    output = root / 'lib/ui/field/tokens.dart'
    generated = generate(data)
    if args.check:
        if not output.exists() or output.read_text(encoding='utf-8') != generated:
            parser.exit(1, 'Field tokens are stale; run python3 tool/generate_field_tokens.py\n')
        print('Field tokens match the product snapshot.')
    else:
        output.write_text(generated, encoding='utf-8')


if __name__ == '__main__':
    main()
