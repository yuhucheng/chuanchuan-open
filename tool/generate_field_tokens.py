"""Generate Flutter values from the distributable product token snapshot.
Run python3 tool/generate_field_tokens.py then dart format lib/ui/field/tokens.dart.
No dependency on a management checkout or external libraries.
"""
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
data = json.loads((root / 'assets/design/design-tokens.json').read_text())
lines = ['// Generated from assets/design/design-tokens.json. Do not edit values by hand.', "import 'package:flutter/material.dart';", 'abstract final class FieldTokens {']
for key, value in data['color'].items():
    lines.append(f"  static const {key} = Color(0xFF{value['value'][1:]});")
for key, value in data['radius'].items():
    lines.append(f'  static const {key}Radius = {float(value)};')
for key, value in data['typography'].items():
    lines.append(f"  static const {key}Style = TextStyle(fontSize: {float(value['size'])}, height: {value['lineHeight'] / value['size']}, fontWeight: FontWeight.w{value['weight']});")
lines += [f"  static const nodeWidth = {float(data['component']['desktopNode']['baseWidth'])};", f"  static const holdDuration = Duration(milliseconds: {data['motion']['holdShortcut']['durationMs']});", '}']
(root / 'lib/ui/field/tokens.dart').write_text('\n'.join(lines) + '\n')
