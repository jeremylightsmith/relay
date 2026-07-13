import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/router.dart';
import 'app/theme.dart';

void main() => runApp(const ProviderScope(child: RelayApp()));

class RelayApp extends ConsumerWidget {
  const RelayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Relay',
      theme: RelayTheme.light,
      darkTheme: RelayTheme.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
