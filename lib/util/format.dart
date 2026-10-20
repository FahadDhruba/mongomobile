/// Number and size formatting without locale dependencies.
library;

/// `1234567` → `1,234,567`.
String groupDigits(int n) {
  final neg = n < 0;
  final s = n.abs().toString();
  final sb = StringBuffer(neg ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) sb.write(',');
    sb.write(s[i]);
  }
  return sb.toString();
}

/// `2412345` → `2.4M`, `12345` → `12.3K`, `999` → `999`.
String compactCount(int n) {
  final a = n.abs();
  String fmt(double v, String unit) {
    final text = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${n < 0 ? '-' : ''}${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}$unit';
  }

  if (a < 1000) return '$n';
  if (a < 1000000) return fmt(a / 1000, 'K');
  if (a < 1000000000) return fmt(a / 1000000, 'M');
  return fmt(a / 1000000000, 'B');
}

/// `1536` → `1.5 KB`.
String formatBytes(int? bytes) {
  if (bytes == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  if (i == 0) return '$bytes B';
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[i]}';
}

/// `1234` ms → `1.23 s`, `85` → `85 ms`.
/// A running time like "850 ms", "12.3 s", "1m 15s" or "2h 5m".
String formatElapsed(Duration d) {
  if (d.inSeconds < 60) return formatDuration(d);
  if (d.inHours == 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

String formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '$ms ms';
  return '${(ms / 1000).toStringAsFixed(ms < 10000 ? 2 : 1)} s';
}
