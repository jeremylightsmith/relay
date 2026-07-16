import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../features/settings/initials.dart';

/// A person's avatar (RLY-90): the Google photo when we have a URL, else
/// white initials on the human-blue circle — SET-01's identity block draws
/// it at 44px (15px text → the 0.34 ratio). No broken-image handling by
/// design [E5]: stale URLs are a known limitation, matching the web.
class RelayAvatar extends StatelessWidget {
  const RelayAvatar({
    super.key,
    this.src,
    this.name,
    this.email,
    this.size = 44,
  });

  final String? src;
  final String? name;
  final String? email;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = src;
    final hasPhoto = url != null && url.isNotEmpty;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        color: RelayTheme.relayHuman,
        shape: BoxShape.circle,
      ),
      child: hasPhoto
          ? Image.network(url, width: size, height: size, fit: BoxFit.cover)
          : Text(
              initialsFor(name, email),
              style: TextStyle(
                fontSize: size * 0.34,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
    );
  }
}
