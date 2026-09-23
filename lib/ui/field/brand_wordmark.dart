import 'package:flutter/material.dart';

import 'brand_wordmark_paths.dart';
import 'tokens.dart';

/// Font-free brand lettering. Body text continues to use the theme's regular
/// weights and system fallbacks; this path never changes the application's font.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.textScalerOf(context)
        .scale(FieldTokens.h3Style.fontSize!);
    return Semantics(
      label: '串串',
      image: true,
      child: SizedBox(
        height: height,
        width: height * brandWordmarkSize.width / brandWordmarkSize.height,
        child: CustomPaint(
          painter: _Wordmark(Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }
}

class _Wordmark extends CustomPainter {
  _Wordmark(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(
      size.width / brandWordmarkSize.width,
      size.height / brandWordmarkSize.height,
    );
    canvas.drawPath(createBrandWordmarkPath(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Wordmark oldDelegate) => color != oldDelegate.color;
}
