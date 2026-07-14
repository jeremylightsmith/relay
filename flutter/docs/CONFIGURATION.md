# Flutter App Configuration

The mobile wrapper picks its API endpoint automatically based on build mode,
via `lib/config/app_config.dart`.

| Build mode | API URL |
| --- | --- |
| Debug (`flutter run`) | `http://localhost:4000` |
| Release / Profile (`flutter build`, `--release`) | `https://relayboard.fly.dev` |

Use it in code with `AppConfig.apiBaseUrl`.

## Overriding the API URL

Compile-time override (no code change):

```bash
# Physical device / simulator against your Mac's dev server
flutter run --dart-define=APP_API_URL=http://192.168.1.100:4000

# Or via the Makefile helper
make ios-lan LAN_IP=192.168.1.100
```

## Platform notes

- **iOS simulator:** `http://localhost:4000` works directly.
- **Android emulator:** use `http://10.0.2.2:4000` (host loopback) — relevant once
  the Android platform is added.
- **Physical device:** use your Mac's LAN IP; the phone and Mac must share a network.
