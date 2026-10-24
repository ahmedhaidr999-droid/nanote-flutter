/// Compact "when" labels for the shelf — "Today", "Yesterday",
/// "12 Mar 2025". Local, no intl dependency.
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String formatWhen(DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  final year = local.year == now.year ? '' : ' ${local.year}';
  return '${local.day} ${_months[local.month - 1]}$year';
}
