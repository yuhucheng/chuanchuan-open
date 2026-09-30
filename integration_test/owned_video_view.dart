import 'package:flutter/material.dart';

// Paint the background inside the exact subtree that the probe reads back.
Widget ownedVideoProbeView(GlobalKey boundaryKey, Widget video) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 480,
        height: 320,
        child: RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(color: Colors.white, child: video),
        ),
      ),
    ),
  ),
);
