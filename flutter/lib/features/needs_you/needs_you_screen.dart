import 'package:flutter/material.dart';
import '../../widgets/placeholder_screen.dart';

class NeedsYouScreen extends StatelessWidget {
  const NeedsYouScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Needs you',
      icon: Icons.check_box_outline_blank,
    );
  }
}
