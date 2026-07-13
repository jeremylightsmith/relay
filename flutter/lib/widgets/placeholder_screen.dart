import 'package:flutter/material.dart';

/// Shared "arriving soon" body for the F1 tabs. Each feature card (F2–F5)
/// replaces its screen wholesale, so this is intentionally presentational.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.icon,
    this.note = 'Arriving soon',
  });

  final String title;
  final IconData icon;
  final String note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.primary),
            const SizedBox(height: 12),
            Text(note, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}
