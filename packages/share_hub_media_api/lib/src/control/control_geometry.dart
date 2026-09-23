import 'package:share_hub_session_api/share_hub_session_api.dart';

/// Describes an already oriented presented image, not an executable OS mapping.
/// Only the target's native owner may resolve its source token and transform
/// these image coordinates into current desktop coordinates after authorization.
final class ControlGeometry {
  ControlGeometry({
    required this.sourceToken,
    required this.revision,
    required this.mediaRevision,
    required this.width,
    required this.height,
    required this.originX,
    required this.originY,
    required this.scaleX,
    required this.scaleY,
    required this.rotation,
  }) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(sourceToken) ||
        revision < 1 ||
        revision > 0x7fffffffffffffff ||
        mediaRevision < 0 ||
        mediaRevision > 0x7fffffff ||
        width < 1 ||
        width > maximumDimension ||
        height < 1 ||
        height > maximumDimension ||
        !originX.isFinite ||
        !originY.isFinite ||
        !scaleX.isFinite ||
        !scaleY.isFinite ||
        scaleX <= 0 ||
        scaleY <= 0 ||
        !const [0, 90, 180, 270].contains(rotation)) {
      throw const SessionFailure('invalid_range');
    }
  }

  static const maximumDimension = 65535;
  final String sourceToken;
  final int revision, mediaRevision, width, height, rotation;
  final double originX, originY, scaleX, scaleY;

  /// The caller must exclude letterboxing before normalizing. This method
  /// neither clamps invalid input nor applies DPI, rotation or desktop origins.
  /// Platform representability and the current revision are separate gates.
  ({double x, double y}) imagePoint(double x, double y) {
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      throw const SessionFailure('invalid_range');
    }
    return (x: x * (width - 1), y: y * (height - 1));
  }
}
