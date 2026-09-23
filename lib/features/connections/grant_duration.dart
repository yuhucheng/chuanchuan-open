import 'package:share_hub_media_api/share_hub_media_api.dart';

String formatGrantDuration(Duration duration) {
  var seconds = duration.inSeconds;
  if (seconds <= 0) return '不足 1 秒';
  final parts = <String>[];
  for (final (unit, label) in const [
    (Duration.secondsPerDay, '天'),
    (Duration.secondsPerHour, '小时'),
    (Duration.secondsPerMinute, '分钟'),
    (1, '秒'),
  ]) {
    final count = seconds ~/ unit;
    if (count != 0) parts.add('$count $label');
    seconds %= unit;
  }
  return parts.join(' ');
}

String formatGrantPolicy(GrantEndpoint grant) {
  final policy = grant.binding.policy;
  final type = policy.type == GrantPolicy.shortCode.type
      ? '短接码授权'
      : '授权类型：${policy.type}';
  return '$type · 总期限 ${formatGrantDuration(policy.lifetime)}';
}
