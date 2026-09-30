import 'dart:typed_data';

class OwnedVideoSampleState {
  const OwnedVideoSampleState(this.session, this.revision, this.stopped);
  final Object session;
  final int revision;
  final bool stopped;

  bool matches(OwnedVideoSampleState? other) =>
      other != null &&
      identical(session, other.session) &&
      revision == other.revision &&
      stopped == other.stopped;
}

Future<OwnedVideoPixels?> readStableOwnedVideoPixels(
  OwnedVideoSampleState sampled,
  OwnedVideoSampleState? Function() current,
  Future<OwnedVideoPixels> Function() read,
) async {
  final pixels = await read();
  return sampled.matches(current()) ? pixels : null;
}

// Scalar observations only. Never persist the sampled pixels.
class OwnedVideoPixels {
  const OwnedVideoPixels({
    this.readable = false,
    this.ownedPattern = false,
    this.cleared = false,
    this.marker,
  });
  final bool readable, ownedPattern, cleared;
  final bool? marker;
}

OwnedVideoPixels inspectOwnedVideoPixels(
  ByteData? pixels,
  int width,
  int height,
) {
  if (pixels == null ||
      width < 4 ||
      height <= 8 ||
      pixels.lengthInBytes != width * height * 4) {
    return const OwnedVideoPixels();
  }
  const colors = [
    [224, 32, 32],
    [32, 208, 64],
    [32, 64, 224],
    [224, 208, 32],
  ];
  var owned = true;
  for (var quadrant = 0; quadrant < 4; quadrant++) {
    final x = (width * (quadrant.isEven ? .25 : .75)).floor();
    final y = (height * (quadrant < 2 ? .25 : .75)).floor();
    final offset = (y * width + x) * 4;
    for (var channel = 0; channel < 3; channel++) {
      if ((pixels.getUint8(offset + channel) - colors[quadrant][channel])
              .abs() >
          45) {
        owned = false;
      }
    }
    if (pixels.getUint8(offset + 3) < 245) owned = false;
  }
  // The probe paints opaque white inside the sampled boundary below video.
  // A grey marker, failed readback or partial/corrupt residual texture is not
  // evidence that the region cleared.
  var cleared = true;
  for (var offset = 0; offset < pixels.lengthInBytes; offset++) {
    if (pixels.getUint8(offset) < 247) {
      cleared = false;
      break;
    }
  }
  final offset = (8 * width + width ~/ 2) * 4;
  final rgb = List.generate(3, (i) => pixels.getUint8(offset + i));
  final bool? marker = rgb.every((value) => value > 190)
      ? true
      : rgb.every((value) => value < 65)
      ? false
      : null;
  return OwnedVideoPixels(
    readable: true,
    ownedPattern: owned,
    cleared: cleared,
    marker: owned ? marker : null,
  );
}
