# Mobile Deployment (TestFlight + Play Store)

Hamaca's mobile app is a thin Flutter wrapper. It ships to **TestFlight** (iOS) and
the **Play Store internal track** (Android) via [fastlane](https://fastlane.tools),
driven by `.github/workflows/flutter-deploy.yml` on every push to `main` that
touches `flutter/**`. Build number = the GitHub run number.

| | iOS | Android |
| --- | --- | --- |
| App identifier | `app.hamaca.Hamaca` | `com.jeremylightsmith.relay` (not shipped as Hamaca yet — [RE485 Ship Hamaca on Android (Play internal testing)]) |
| Signing | fastlane `match` (certs in a private git repo) | upload keystore + `key.properties` |
| Target | TestFlight | Play Store internal testing |

- **Apple Team ID:** `CR8KT24FBH` · **App Store Connect Apple ID:** `6827052680`
- **Production host:** `https://hamaca.app`. Release builds bake it in from the
  `RELAY_BASE_URL` dart-define (`ios/fastlane/Fastfile` → `lib/config.dart`).
  **Human step:** the deploy runner reads `RELAY_BASE_URL` from its `.envrc.local`
  (not in the repo) — set it to `https://hamaca.app` (as `.envrc.local.example`
  shows) and restart the runner. Set `GOOGLE_IOS_CLIENT_ID` there to the Hamaca
  iOS OAuth client too; its reversed form is the URL scheme in `Runner/Info.plist`.
- **Push topic:** `APNS_TOPIC = 'app.hamaca.Hamaca'` in `fly.toml`. Tokens the
  legacy Relay app registered get `400 DeviceTokenNotForTopic` and are pruned.
- **iOS local dev signing:** Xcode automatic signing (already pinned to the team in
  `Runner.xcodeproj`). `match` flips to manual signing only for release archives.

Modeled on the sibling `../rotation` project.

## One-time setup

These steps are manual — do them once, then CI + `make deploy-ios` just work. For
the Hamaca app they were done by hand in [RE484 Hamaca app: console and store setup
(by hand)] — that card is the record of the console steps (App ID, App Store
Connect app, Sign in with Apple, push key, Google iOS OAuth client).

### 1. Register the app with Apple

1. **App Store Connect → My Apps → +** → New App.
   - Platform: iOS · Bundle ID: `app.hamaca.Hamaca` (create the App ID
     first under *Certificates, IDs & Profiles → Identifiers* if it isn't listed,
     with Sign in with Apple and Push Notifications enabled).
   - SKU: `hamaca-ios`.

### 2. Signing profile via match (reuses rotation-creds)

`match` stores encrypted certs/profiles in a private repo. Because relay shares
Apple team `CR8KT24FBH` with rotation (and a Distribution cert is team-wide), relay's
Matchfile points at the **existing `rotation-creds`** repo rather than a new one — it
reuses rotation's Distribution cert and just adds relay's App Store profile.

Run once, locally, from `flutter/ios` (uses rotation's existing `MATCH_PASSWORD`):
```bash
mise exec -- fastlane match appstore
```
This creates `profiles/appstore/AppStore_app.hamaca.Hamaca.mobileprovision`
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

## Store listing (iOS)

The App Store listing is committed as fastlane `deliver` files:

- `ios/fastlane/metadata/en-US/*.txt`: name, subtitle, description, keywords,
  promotional text, and the support / privacy / marketing URLs. `bin/test_deploy.py`
  (`StoreListingTest`) holds App Store Connect's length limits. There's no
  `release_notes.txt` because App Store Connect rejects "What's New" on an app's first version.
- `ios/fastlane/screenshots/en-US/*.png`: the framed store screenshots. `deliver`
  infers the device size from pixel dimensions. 6.9" (1320×2868) needs fastlane ≥ 2.222.

`fastlane ios upload_listing` (from `flutter/ios`) uploads the metadata and screenshots
to the editable App Store version and renames that version to `APP_VERSION`. It **never
uploads a binary and never submits for review** (`skip_binary_upload: true`,
`submit_for_review: false`, `automatic_release: false`). Submitting is a human step in
App Store Connect.

- **When Deploy runs it:** `bin/deploy_ios.sh <REF>` runs it after the TestFlight
  steps, and only when the card's commit changed `ios/fastlane/metadata` or
  `ios/fastlane/screenshots`. `bin/deploy_ios.sh --head` always runs it (`deliver`
  is idempotent).
- **By hand:** from `flutter/ios`, with the App Store Connect API key exported:
  ```bash
  APP_VERSION=1.0.0 FASTLANE_API_KEY_PATH=/path/to/AuthKey_XXX.p8 \
    APP_STORE_CONNECT_KEY_ID=... APP_STORE_CONNECT_ISSUER_ID=... \
    mise exec -- fastlane ios upload_listing
  ```

## Store screenshots

The four App Store shots (Needs you, Board, Review, Answer) are real captures of the app,
taken on an iPhone 6.9" simulator against a **local dev server** seeded with "Forkful", a
recipe-site board owned by the dev user. Nothing is staged on prod. Re-render them in three
steps, from the repo root:

1. **Seed** (idempotent; rebuilds the board):
   `mix run priv/repo/store_screenshot_seeds.exs`, then start `mix phx.server`.
2. **Capture**: `bin/capture_store_screenshots.sh [SIMULATOR_UDID]` (default: the first
   iPhone 16+ Pro Max). It pins the status bar to 9:41 with full signal and battery, sets
   light mode, runs `integration_test/store_screenshots_test.dart` (which signs in through
   `/dev/login` and walks to each screen) and screenshots the simulator on each
   `HAMACA_SHOT <name>` marker into `ios/fastlane/screenshots_raw/en-US/`.
3. **Render**: `node bin/store-screenshots.mjs` frames and captions the raw shots into
   `ios/fastlane/screenshots/en-US/` at 1320×2868, as the store-listing mockup draws them.

The raw captures sit outside `screenshots/` so `deliver` never uploads them. The recipe photo
in the seeded mockups is CC0, so the shots need no credit
(`priv/repo/store_screenshot_seeds/PHOTO_SOURCE.md`). If the dev user's other local boards
crowd the Needs-you inbox, re-capture against a reset dev DB.

## Local device / simulator

- **Simulator (no signing):** `cd flutter && make ios`
- **Physical device:** pull the development profile first:
  ```bash
  cd flutter && make pull-credentials   # runs `fastlane match development`
  make ios                              # or: flutter run -d <device-id>
  ```
- **Against a LAN dev server:** `make ios-lan LAN_IP=192.168.86.30`

See [CONFIGURATION.md](CONFIGURATION.md) for how `AppConfig` picks the API URL.
