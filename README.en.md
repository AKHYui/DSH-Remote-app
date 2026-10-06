# DSH Remote
[简体中文](README.md) | **English**

Drive a DeepSeek Harness desktop from your phone: list sessions, watch live output, send messages, handle approvals and questions.

## What it is

DSH Remote is the phone side of the chain: a Flutter client that talks only to **the relay you host
yourself** (HTTPS + WSS) and never connects to the desktop directly, so it works behind home NAT and
without a public IP. It needs two companion components: the
[relay backend](https://github.com/AKHYui/DSH-Remote-backend) and the
[desktop plugin](https://github.com/AKHYui/DSH-Remote-plugin). The wire protocol between all three is
defined by [docs/PROTOCOL.md](https://github.com/AKHYui/DSH-Remote-backend/blob/main/docs/PROTOCOL.md) in the backend repository.

Current version **0.2.6** (`pubspec.yaml`: `version: 0.2.6+11`). The launcher label is `DSH Remote` and
the applicationId is `com.dshremote.dsh_remote_app` — the id is kept stable across releases so an
in-place upgrade preserves pairing and settings.

## Architecture

```
 ┌────────────┐   HTTPS / WSS    ┌───────────────┐   outbound WSS   ┌────────────────┐
 │ DSH Remote │ ───────────────▶ │     relay     │ ◀─────────────── │ desktop plugin │
 │  (Android) │                  │ FastAPI+SQLite│                  │   (in DSH)     │
 └────────────┘                  └───────────────┘                  └────────────────┘
```

The phone talks only to the relay; the desktop plugin dials out to it, so the desktop opens no inbound
port. Everything runs over TLS, signed by your own internal CA, whose **public certificate** ships in
`assets/ca.crt`.

## Requirements

| Component | Version | Notes |
|---|---|---|
| Flutter SDK | 3.47.6 (Dart 3.13.5) | `flutter doctor` should report no errors; `pubspec.yaml` requires Dart `>=3.4.0 <4.0.0` |
| JDK | 17 | Gradle and Kotlin both target JVM 17 (`sourceCompatibility` / `jvmTarget`) |
| Android SDK | platform 36, build-tools 36.0.0 | `compileSdk` / `targetSdk` follow the Flutter defaults; the built APK covers API 24–36 |
| Phone or emulator | Android 7.0 (API 24) or newer | The phone must match one of the APK's ABIs; an x86_64 emulator needs the dedicated build (below) |
| Android platform-tools | any | Provides `adb` and `apkanalyzer` |
| Python + Pillow | Python 3.9+ | Needed **only** to regenerate the icons; normal builds do not use it |

## Build and install

### 1. Get the code and dependencies

```bash
git clone https://github.com/AKHYui/DSH-Remote-app.git
cd DSH-Remote-app
flutter pub get
```

### 2. Static analysis and tests

```bash
flutter analyze     # expected: No issues found!
flutter test        # 246 cases; needs no device and no network
```

### 3. Build the release APK

```bash
# Universal package (arm64-v8a / armeabi-v7a / x86_64): for physical phones
flutter build apk --release

# x86_64-only package: for x86_64 emulators such as MuMu
flutter build apk --release --target-platform android-x64
```

Both produce `build/app/outputs/flutter-apk/app-release.apk`.

Which one you need depends on the emulator's **primary ABI**:

```bash
adb shell getprop ro.product.cpu.abi     # e.g. x86_64 or arm64-v8a
```

If the primary ABI is x86_64 (some emulators report this even on an ARM host), the universal package
runs through ARM translation and may start to a black screen with `Width is zero. 0,0` in the log.
Use the `--target-platform android-x64` build in that case.

### 4. Install on the phone

```bash
adb devices
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Without `adb`, copy the APK to the phone and sideload it. The applicationId is unchanged, so this is an
in-place upgrade and both pairing and settings are preserved.

### 5. Check the artifact before handing it out

```bash
# Any platform (apkanalyzer ships with the Android SDK cmdline-tools)
apkanalyzer manifest permissions build/app/outputs/flutter-apk/app-release.apk
apkanalyzer files list         build/app/outputs/flutter-apk/app-release.apk | grep '^/lib/'
```

```powershell
# Windows: the same checks as a script (INTERNET permission plus the actual ABI set)
powershell -ExecutionPolicy Bypass -File tool/verify_apk.ps1 -Apk build/app/outputs/flutter-apk/app-release.apk
```

Two things always have to hold: the manifest declares `android.permission.INTERNET`, and `lib/`
contains an ABI that the target device can run.

### 6. Signing

Release builds in this repository use the **debug signing key**
(`signingConfig = getByName("debug")` in `android/app/build.gradle.kts`), which is fine for sideloading
and personal use. To publish to an app store, supply your own keystore, write
`android/key.properties`, and point `buildTypes.release` at your signingConfig. `key.properties`,
`*.jks` and `*.keystore` are already in `.gitignore` and are never committed.

### 7. Icons (optional)

```bash
python tool/make_icons.py     # requires Pillow
```

The source art is `tool/icon/app_icon.png`. The script emits both halves of the icon set in one run:
`mipmap-{mdpi..xxxhdpi}/ic_launcher.png` (legacy icons) and `mipmap-*/ic_launcher_foreground.png`
plus `mipmap-anydpi-v26/ic_launcher.xml` (API 26+ adaptive icon, with its background colour in
`values/colors.xml`).

## First-time setup

1. Issue a phone token from the backend repository:

   ```bash
   python -m app.cli issue-device --name "my phone"     # issue directly
   # or pair: pair-start → pair-approve <code> on the server → claim the code in the app's settings
   ```

2. Open the app → **Settings** and enter the **relay URL** (for example
   `https://relay.example.com:58443`) and the **device token**. The URL may also be given as plain
   `host:port`; the app normalises it to `https://host[:port]`.

3. If the relay uses an internal CA, you do **not** have to install it into the system trust store: it
   ships inside the APK (`assets/ca.crt`) and is loaded into a `SecurityContext`, so public HTTPS keeps
   working as before. The settings screen shows that CA's SHA-256 fingerprint so you can compare it
   with `certs/ca.crt` on the server.

The token is stored in the platform Keystore / Keychain via `flutter_secure_storage`; it never goes to
SharedPreferences and never enters the repository.

## Features and limits

| Feature | Notes |
|---|---|
| Session list | Sessions grouped by workspace; subagent sessions and never-prompted (empty) tasks are filtered out |
| History | A session snapshot is bounded by **bytes**, not just by a message count — one long turn can fill the whole window — so scrolling back fetches the previous page with `session.page`; the top of the list tells you whether there is more to fetch, whether it is loading, or that you have reached the beginning |
| Live stream | Opening a session subscribes to `session.follow`: snapshot first, then live events; reconnects on its own, again when the app returns to the foreground, and **also when a half-open connection dies silently** — see Operations and troubleshooting |
| Sending | Text appears as soon as it is accepted (local echo, reconciled with the durable event); the current turn can be cancelled |
| Attachments | Images are inlined in `session.prompt`; anything else is uploaded first for a `receiptId` and sent with the message |
| Model | Switch provider / model per session; the options come from `model.catalog` |
| Approvals and questions | The phone and the desktop both show the request; whichever answers first wins, and the desktop window closes itself afterwards |
| Deliverables | Shows the files declared with `present` (path and description) without downloading or displaying their contents |
| Usage line | The desktop's own numbers, under the conversation: `N turns M steps · K tok/s · total tokens · cache hit · context used`, with the breakdown (mode, permission, uncached input, cache read/write, output, context occupancy) a tap away. Read from DSH's session projections with the same formulas the desktop uses |
| Mode when creating | A new task can be created in any of DSH's four modes: **Standard / PTC / Minimal / Creator** (agent presets). The mode locks once the session starts, so creation is the only chance to pick; the last choice is remembered and pre-selected, and the task breakdown shows the current one |

| Limit | Value |
|---|---|
| One attachment | **2 MiB** of raw bytes (the relay's request body cap is 4 MiB and base64 inflates by 4/3) |
| Images | Downscaled on the native side to a **2000 px** long edge, quality 85; PNG / JPEG / WebP / GIF |
| HEIC / HEIF | **Not supported**: rejected at pick time, convert to JPEG or PNG first |
| Other files | Any type, up to 2 MiB each |

## Operations and troubleshooting

| Symptom | What to do |
|---|---|
| You need logs | `adb logcat` (Flutter output is under the `flutter` tag); the settings screen also shows the event-channel state and the last error |
| The desktop already answered but the phone still spins or never refreshes | The follow stream is a long-lived connection, and **a dead one need not report anything**: a half-open HTTP response neither errors nor ends. The app notices and re-opens it by itself — when the event socket says the session moved, or when a message of yours stays unconfirmed, it re-fetches an authoritative snapshot; `adb logcat` shows a `[dsh-remote] re-opening the follow stream: …` line. If nothing refreshes within 30s, check that the relay and the desktop plugin are online (the settings screen shows the event-channel state) |
| A release build cannot reach the network | The main manifest is missing `android.permission.INTERNET`. The debug and profile manifests declare it, the release one does not; verify with `apkanalyzer manifest permissions` |
| A session archived on the desktop still shows in the list | Opening the drawer reloads the list; if it still shows, confirm the desktop plugin was restarted (plugin source changes only take effect after a DSH restart) |
| The emulator shows a black screen and the log says `Width is zero. 0,0` | Its primary ABI is x86_64 but the universal package is installed; rebuild with `--target-platform android-x64` |
| The "submit answer" button stays greyed out | The answer is incomplete: a question with options needs a selection, one without needs typed text; "hand back to the desktop" is always available |
| Gradle download fails on a fresh clone | `android/gradle/wrapper/gradle-wrapper.properties` points at a Tencent mirror; change it back to `services.gradle.org` if that suits your network |
| Rebuilding plugins got slower | `kotlin.incremental=false` in `android/gradle.properties` is deliberate (Kotlin incremental caches failed the build here); the cost is slower repeat builds of the plugins |

## Tests

```bash
flutter test                                    # 246 cases: no device, no network

# 9 integration checks against a live relay (needs a real relay and a device token)
export DSH_LIVE_RELAY='https://relay.example.com:58443'
export DSH_LIVE_TOKEN='<device-token>'
export DSH_LIVE_CA='assets/ca.crt'              # optional; this is the default
flutter test test/live_relay_test.dart
```

On Windows PowerShell use `$env:DSH_LIVE_RELAY='…'` instead. Without `DSH_LIVE_RELAY` and
`DSH_LIVE_TOKEN` that whole group is skipped.

## Repository layout

```
lib/api/     relay HTTP + SSE/WebSocket client, models, TLS trust and CA fingerprint
lib/chat/    event stream → transcript, Markdown subset, attachment contract (pure Dart)
lib/state/   settings (token in the Keystore) and application state
lib/ui/      setup, device and task lists, conversation view, settings, attachment picking
test/        246 unit / widget cases plus the 9 live-relay checks
tool/        verify_apk.ps1 (pre-delivery check), make_icons.py and icon/ (icon source art)
android/     the Android project: applicationId, manifest, launcher icon resources
assets/      ca.crt (the relay's public CA certificate)
```

## Related repositories

- Desktop plugin: https://github.com/AKHYui/DSH-Remote-plugin
- Relay backend (authoritative protocol definition): https://github.com/AKHYui/DSH-Remote-backend
- Phone app (this repository): https://github.com/AKHYui/DSH-Remote-app

## License

MIT, see [LICENSE](LICENSE).
