/// "3 min ago", "yesterday"… for when a task last ran or a device was seen.
String timeAgo(DateTime? at, {DateTime? now}) {
  if (at == null) return 'never';
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  if (d.inDays < 30) return '${d.inDays} days ago';
  return '${at.year}-${'${at.month}'.padLeft(2, '0')}-${'${at.day}'.padLeft(2, '0')}';
}
