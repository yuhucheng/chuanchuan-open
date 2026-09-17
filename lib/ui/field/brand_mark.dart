import 'package:flutter/material.dart';

/// Geometry from the supplied monochrome SVG; no external font dependency.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '串串标志',
    image: true,
    child: SizedBox.square(
      dimension: 32,
      child: CustomPaint(
        painter: _Mark(Theme.of(context).colorScheme.onSurface),
      ),
    ),
  );
}

class _Mark extends CustomPainter {
  _Mark(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120, size.height / 120);
    canvas.translate(10, 10);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 7
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter;
    canvas.drawPath(
      Path()
        ..moveTo(18, 64)
        ..lineTo(18, 55)
        ..lineTo(25, 48)
        ..lineTo(75, 48)
        ..lineTo(82, 55)
        ..lineTo(82, 64),
      stroke,
    );
    canvas.drawLine(const Offset(50, 22), const Offset(50, 50), stroke);
    for (final x in [6.0, 70.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 64, 24, 24),
          const Radius.circular(5),
        ),
        stroke,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(43, 8, 14, 14),
        const Radius.circular(3),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_Mark oldDelegate) => color != oldDelegate.color;
}
