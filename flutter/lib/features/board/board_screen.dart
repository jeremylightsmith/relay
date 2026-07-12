import 'package:flutter/material.dart';
import '../../widgets/placeholder_screen.dart';

class BoardScreen extends StatelessWidget {
  const BoardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(title: 'Board', icon: Icons.grid_view);
  }
}
