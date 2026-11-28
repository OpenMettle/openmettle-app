import 'package:material_ui/material_ui.dart';

class HistoryChoice extends StatelessWidget {
  const HistoryChoice({
    super.key,
    required this.label,
    required this.createdAt,
    required this.onPressed,
    this.note,
    this.focusNode,
  });

  final String label;
  final String createdAt;
  final VoidCallback onPressed;
  final String? note;
  final FocusNode? focusNode;

  String _creationLabel(BuildContext context) {
    final local = DateTime.parse(createdAt).toLocal();
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatShortDate(local);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final offset = local.timeZoneOffset.inMinutes;
    if (offset == 0) return 'Created $date at $time (UTC)';

    final sign = offset < 0 ? '-' : '+';
    final hours = (offset.abs() ~/ 60).toString().padLeft(2, '0');
    final minutes = (offset.abs() % 60).toString().padLeft(2, '0');
    return 'Created $date at $time (UTC$sign$hours:$minutes)';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton(
              focusNode: focusNode,
              onPressed: onPressed,
              child: Text(label, textAlign: TextAlign.start),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                [_creationLabel(context), ?note].join('\n'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
