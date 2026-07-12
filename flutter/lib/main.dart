// Relay Mobile — SPIKE (RLY mobile). Goal: prove Relay's LiveView UI can be
// embedded inside a Flutter iOS app with (1) an authenticated session, (2) a
// live websocket, and (3) acceptable native<->web feel.
//
// The whole hybrid in miniature: a NATIVE inbox list (Flutter widgets) that taps
// into an EMBEDDED LiveView board (flutter_inappwebview). Auth is the interesting
// bit — we grab a Phoenix session cookie natively via /dev/login and inject it
// into the webview so the embedded LiveView renders signed-in (mirrors the real
// native-auth -> webview-inherits-session path).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// iOS simulator shares the host network, so localhost hits the mac's `mix phx.server`.
const String relayBase = 'http://localhost:4003';
const String boardPath = '/board/spike'; // seeded for dev@relay.local (see priv/repo/spike_seed.exs)
const String sessionCookie = '_relay_key';

void main() => runApp(const RelaySpikeApp());

class RelaySpikeApp extends StatelessWidget {
  const RelaySpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Relay Mobile (spike)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE)),
        useMaterial3: true,
      ),
      // Default entry is the native inbox; build with --dart-define=WEB_HOME=true
      // to launch straight into the embedded LiveView board (for spike screenshots).
      home: const bool.fromEnvironment('WEB_HOME')
          ? const CardWebView(title: 'Spike Board')
          : const InboxScreen(),
    );
  }
}

/// A stub of the native "Needs you" inbox. The inbox itself isn't the risky part
/// of the spike (it's plain native UI), so it's hardcoded — every row taps into
/// the embedded LiveView, which IS the thing we're de-risking.
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key});

  static const _items = [
    (ref: 'RLY-14', title: 'Multi-region data residency', state: 'NEEDS INPUT', color: Color(0xFFB26B00)),
    (ref: 'RLY-31', title: 'Rate-limiter middleware', state: 'REVIEW', color: Color(0xFFB26B00)),
    (ref: 'RLY-08', title: 'Org-level RBAC', state: 'WORKING', color: Color(0xFF7C4DFF)),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Needs you'),
        backgroundColor: const Color(0xFF3D5AFE),
        foregroundColor: Colors.white,
      ),
      body: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final item = _items[i];
          return ListTile(
            title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(item.ref),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: item.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(item.state,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: item.color)),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => CardWebView(title: item.ref)),
            ),
          );
        },
      ),
    );
  }
}

/// The embedded-LiveView surface. Authenticates natively, then loads the board.
class CardWebView extends StatefulWidget {
  const CardWebView({super.key, required this.title});
  final String title;

  @override
  State<CardWebView> createState() => _CardWebViewState();
}

class _CardWebViewState extends State<CardWebView> {
  Future<void>? _auth;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _auth = _authenticate();
  }

  void _retry() => setState(() => _auth = _authenticate());

  /// Grab a Phoenix session cookie natively (dev-login) and inject it into the
  /// webview's cookie store, so the embedded LiveView loads already signed-in.
  Future<void> _authenticate() async {
    final dio = Dio(BaseOptions(
      baseUrl: relayBase,
      followRedirects: false,
      validateStatus: (s) => s != null && s < 400,
    ));
    final resp = await dio.get('/dev/login'); // 302 + Set-Cookie: _relay_key=...
    final setCookies = resp.headers.map['set-cookie'] ?? const [];

    final cm = CookieManager.instance();
    for (final raw in setCookies) {
      final pair = raw.split(';').first.trim(); // "_relay_key=SFMy..."
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      final name = pair.substring(0, eq);
      final value = pair.substring(eq + 1);
      if (name != sessionCookie) continue;
      await cm.setCookie(
        url: WebUri(relayBase),
        name: name,
        value: value,
        domain: 'localhost',
        path: '/',
        isSecure: false,
        isHttpOnly: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: const Color(0xFF3D5AFE),
        foregroundColor: Colors.white,
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress == 0 ? null : _progress),
              )
            : null,
      ),
      body: FutureBuilder<void>(
        future: _auth,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Couldn\'t reach Relay at $relayBase\n\n${snap.error}',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _retry, child: const Text('Retry')),
                  ],
                ),
              ),
            );
          }
          return InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri('$relayBase$boardPath')),
            initialSettings: InAppWebViewSettings(
              transparentBackground: true,
              // LiveView drives its own DOM; let it own scrolling/zoom.
              supportZoom: false,
            ),
            onProgressChanged: (_, p) => setState(() => _progress = p / 100),
          );
        },
      ),
    );
  }
}
