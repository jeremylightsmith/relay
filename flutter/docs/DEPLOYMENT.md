# Mobile Deployment (TestFlight + Play Store)

Relay's mobile app is a thin Flutter wrapper. It ships to **TestFlight** (iOS) and
the **Play Store internal track** (Android) via [fastlane](https://fastlane.tools),
driven by `.github/workflows/flutter-deploy.yml` on every push to `main` that
touches `flutter/**`. Build number = the GitHub run number.

| | iOS | Android |
| --- | --- | --- |
| App identifier | `com.jeremylightsmith.Relay` | `com.jeremylightsmith.relay` |
| Signing | fastlane `match` (certs in a private git repo) | upload keystore + `key.properties` |
| Target | TestFlight | Play Store internal testing |

- **Apple Team ID:** `CR8KT24FBH`
- **iOS local dev signing:** Xcode automatic signing (already pinned to the team in
  `Runner.xcodeproj`). `match` flips to manual signing only for release archives.

Modeled on the sibling `../rotation` project.

## One-time setup

These steps are manual — do them once, then CI + `make deploy-ios` just work.

### 1. Register the app with Apple

1. **App Store Connect → My Apps → +** → New App.
   - Platform: iOS · Bundle ID: `com.jeremylightsmith.Relay` (create the App ID
     first under *Certificates, IDs & Profiles → Identifiers* if it isn't listed).
   - SKU: anything unique (e.g. `relay-ios`).

### 2. Signing profile via match (reuses rotation-creds)

`match` stores encrypted certs/profiles in a private repo. Because relay shares
Apple team `CR8KT24FBH` with rotation (and a Distribution cert is team-wide), relay's
Matchfile points at the **existing `rotation-creds`** repo rather than a new one — it
reuses rotation's Distribution cert and just adds relay's App Store profile.

Run once, locally, from `flutter/ios` (uses rotation's existing `MATCH_PASSWORD`):
```bash
mise exec -- fastlane match appstore
```
This creates `profiles/appstore/AppStore_com.jeremylightsmith.Relay.mobileprovision`
in `rotation-creds`. It will **not** mint a new cert (Apple caps Distribution certs at
2 per team) — if you ever see a "certificate is invalid / revoked" build error, delete
stale duplicates from your keychain: `security delete-identity -Z <SHA-1>`.

### 3. App Store Connect API key (for uploads)

1. **App Store Connect → Users and Access → Integrations → App Store Connect API**
   → generate a key with **App Manager** role.
2. Download the `.p8`. Note the **Key ID** and **Issuer ID**.

### 4. GitHub secrets & variables

Set these on the **relay** repo (Settings → Secrets and variables → Actions):

**Secrets**
| Name | Value |
| --- | --- |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The raw `.p8` contents, base64-encoded (`base64 -i AuthKey_XXX.p8`) |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APPLICATION_SPECIFIC_PASSWORD` | App-specific password from appleid.apple.com |
| `MATCH_PASSWORD` | The **rotation-creds** passphrase (relay reuses that repo — see note below) |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `base64` of `<github-username>:<PAT-with-repo-scope>` (read access to `rotation-creds`) |

**Variables**
| Name | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | The Key ID from step 3 |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID from step 3 |

> **Signing repo:** relay and rotation share Apple team `CR8KT24FBH`, and an Apple
> Distribution cert is team-wide — so relay's Matchfile points at **`rotation-creds`**
> (not a separate repo) and reuses the existing cert. Use rotation's `MATCH_PASSWORD`.
>
> **API key:** the workflow base64-decodes `APP_STORE_CONNECT_PRIVATE_KEY` to a `.p8`,
> and the Fastfile builds the key object from that `.p8` + `APP_STORE_CONNECT_KEY_ID` +
> `APP_STORE_CONNECT_ISSUER_ID` (via `app_store_connect_api_key`). Locally, the same three
> live in `.envrc.local` as `FASTLANE_API_KEY_PATH` / `APP_STORE_CONNECT_KEY_ID` /
> `APP_STORE_CONNECT_ISSUER_ID`.

## Android one-time setup

### 1. Create the app record

**Play Console → Create app** → package name `com.jeremylightsmith.relay`.

### 2. Generate an upload keystore

```bash
keytool -genkey -v -keystore ~/keystore/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

For local release builds, create `flutter/android/key.properties` (git-ignored):

```
storePassword=<store-password>
keyPassword=<key-password>
keyAlias=upload
storeFile=/Users/you/keystore/upload-keystore.jks
```

### 3. Play Store service account

**Play Console → Setup → API access** → create/link a Google Cloud service account
with the *Release manager* role, download its JSON key.

### 4. GitHub secrets & variables (Android)

**Secrets:** `ANDROID_KEYSTORE_BASE64` (`base64 -i upload-keystore.jks`),
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`,
`PLAY_STORE_CONFIG_JSON_BASE64` (`base64 -i service-account.json`).
**Variables:** `ANDROID_KEY_ALIAS` (e.g. `upload`).

> Note: Play Store won't accept an upload via the API until the **first AAB has been
> uploaded manually** through the Play Console (Google's one-time requirement).

## Deploying

- **Automatic:** push to `main` touching `flutter/**`. CI validates, then builds iOS
  (Xcode 26 → TestFlight) and Android (→ Play internal) in parallel.
- **Manual (CI):** Actions → *Flutter Deploy* → *Run workflow*.
- **Local:** `cd flutter && make deploy-ios BUILD_NUMBER=999` or
  `make deploy-android BUILD_NUMBER=999`
  (needs Ruby 3.2+, `fastlane` installed, and the relevant env vars).

## Local device / simulator

- **Simulator (no signing):** `cd flutter && make ios`
- **Physical device:** pull the development profile first:
  ```bash
  cd flutter && make pull-credentials   # runs `fastlane match development`
  make ios                              # or: flutter run -d <device-id>
  ```
- **Against a LAN dev server:** `make ios-lan LAN_IP=192.168.86.30`

See [CONFIGURATION.md](CONFIGURATION.md) for how `AppConfig` picks the API URL.
