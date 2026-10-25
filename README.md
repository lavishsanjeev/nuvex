# Nuvex ☁️

**Nuvex** is a lightweight, privacy-focused Android media gallery and cloud storage companion powered by Telegram's distributed cloud infrastructure. It turns your Telegram account into an unlimited, encrypted personal media library with lightning-fast local indexing, hardware-accelerated video streaming, and an AES-256 encrypted Locked Folder.

---

## 🌟 Key Features

- **Direct Telegram Cloud Sync**: Connects directly via Telegram MTProto client without intermediate third-party servers.
- **Local-First Speed (SQLite)**: Instant gallery browsing cached locally in SQLite; never re-downloads thumbnails you already have.
- **Hardware-Accelerated Video Streaming**: Smooth playback with chunked byte-range prefetching and local caching proxy.
- **AES-256-GCM Locked Folder**: Sensitive photos and videos are genuinely encrypted at rest in app-private storage, protected by PIN or biometrics. Locked media is strictly excluded from public queries, thumbnails, and shared directories.
- **Multi-Selection & Batch Actions**: Select multiple media items to save to device gallery, share via Android FileProvider, or securely move to the Locked Folder.
- **In-App Update Notifications**: Seamless, non-intrusive update discovery for GitHub APK releases with semantic version checking and release note summaries.
- **Google Takeout Migration Engine**: Local-first queue engine to migrate historical archives into Telegram storage safely.

---

## 📱 Requirements

- **Platform**: Android
- **Minimum Android Version**: Android 5.0 (API level 21) or higher
- **Target Android Version**: Android 14 / 15 (API level 34+)
- **Architecture**: Universal APK (`arm64-v8a`, `armeabi-v7a`, `x86_64`)

---

## 📥 Download & Installation Guide

Nuvex is distributed directly as an APK through official GitHub Releases.

### 1. Download APK
1. Go to the [Official GitHub Releases](https://github.com/lavishsanjeev/Nuvex/releases/latest).
2. Under **Assets**, tap `app-release.apk` (or `nuvex-release.apk`) to download the latest stable build.

### 2. Install on Android
When opening the downloaded `.apk` file, Android may show a security notice:
> *"For your security, your phone is not allowed to install unknown apps from this source."*

**How to proceed:**
1. Tap **Settings** on the prompt.
2. Toggle **Allow from this source** (for Chrome, Files, or your browser).
3. Return to the installer and tap **Install**.
4. Nuvex is now installed and ready to open!

---

## 🔑 Telegram API Setup & Login

To connect Nuvex to your Telegram cloud:

1. Log in to [my.telegram.org](https://my.telegram.org) with your Telegram phone number.
2. Navigate to **API development tools**.
3. Create a new application entry (e.g., App title: `Nuvex`, Short name: `nuvex`).
4. Copy your **API ID** (an integer) and **API Hash** (a 32-character hex string).
5. Open Nuvex, enter your API ID and API Hash on the setup screen, and tap **Save & Connect**.
6. Enter your phone number (with country code, e.g. `+1...` or `+91...`).
7. Enter the official Telegram login code delivered to your Telegram app or SMS.
8. If your account has Two-Step Verification (2FA) enabled, enter your cloud password.

> **Security Note:** Your credentials, auth keys, and session data are stored strictly on your local device using Android KeyStore-backed secure storage. Nuvex never transmits your credentials to any third-party server.

---

## 🛡️ Privacy & Security Architecture

Nuvex is designed from the ground up for data integrity:

| Data Type | Storage Location | Protection Level |
| :--- | :--- | :--- |
| **Telegram Credentials & Session** | Android KeyStore (`flutter_secure_storage`) | Hardware-backed encryption; never logged |
| **Media Metadata & Index** | Local SQLite (`nuvex_storage.db`) | App-private storage; excluded from Android media scanners |
| **Thumbnail & Streaming Cache** | App Cache directory (`.nomedia` protected) | Automatically pruned; hidden from device gallery |
| **Locked Folder Media** | App-private directory (`nuvex_locked`) | AES-256-GCM authenticated encryption; zero plaintext at rest |
| **Exported / Saved Media** | Public storage (`Pictures/Nuvex`, `Movies/Nuvex`) | Standard MediaStore permissions upon explicit user action |

- **No Analytics / Telemetry**: No tracking SDKs, ad networks, or third-party loggers are bundled.
- **No Log Leakage**: Phone numbers, session tokens, passwords, and private file paths are stripped from production logs.

---

## 🔔 In-App Updates System

When a newer version of Nuvex is published on GitHub, existing users automatically receive a Nuvex-branded update prompt upon launching the app:

- **Non-blocking**: Checks asynchronously in the background without delaying app startup or freezing the gallery.
- **Throttled**: Checks are throttled to once every 4 hours per session to respect user bandwidth and GitHub rate limits.
- **Update Manifest (`version.json`)**: Hosted on the repository's `main` branch.
  - Compares semantic versions (e.g. `1.10.0` > `1.9.0`).
  - Supports optional updates (dismissible with **Later**) and mandatory updates (security/critical fixes).
  - Tapping **Update** opens the official GitHub Release APK download page.

---

## 🚀 Publishing a New Version (For Maintainers)

Follow these steps to publish an upgrade:

### Step 1: Update App Version & Code
In `pubspec.yaml`, increment the version number and build number:
```yaml
version: 1.0.1+2 # format: major.minor.patch+buildNumber
```
Update `lib/core/config/app_version.dart`:
```dart
static const String currentVersion = '1.0.1';
static const int currentBuildNumber = 2;
```

### Step 2: Build the Release APK
```bash
flutter pub get
flutter test
flutter build apk --release
```
The output APK is generated at `build/app/outputs/flutter-apk/app-release.apk`.

### Step 3: Create GitHub Release
1. Tag the release: `git tag v1.0.1 && git push origin v1.0.1`
2. Go to `https://github.com/lavishsanjeev/Nuvex/releases/new`.
3. Choose tag `v1.0.1`.
4. Enter release title (e.g. `Nuvex v1.0.1`).
5. Upload `app-release.apk` as a release asset.
6. Publish release.

### Step 4: Update the In-App Manifest
Update `version.json` in the root of the repository:
```json
{
  "latest_version": "1.0.1",
  "build_number": 2,
  "min_supported_version": "1.0.0",
  "is_mandatory": false,
  "release_date": "2026-10-24",
  "release_notes": "Summary of what's new in v1.0.1...",
  "download_url": "https://github.com/lavishsanjeev/Nuvex/releases/latest",
  "apk_url": "https://github.com/lavishsanjeev/Nuvex/releases/latest/download/app-release.apk"
}
```
Commit and push `version.json` to `main`. Existing installations will automatically detect the new version.

---

## 🛠️ Building From Source

### Prerequisites
- [Flutter SDK](https://flutter.dev) (v3.47+ recommended)
- Android SDK (API 34+)
- JDK 17

### Build Steps
```bash
# Clone the repository
git clone https://github.com/lavishsanjeev/Nuvex.git
cd Nuvex

# Install dependencies
flutter pub get

# Run tests
flutter test

# Run app in debug mode
flutter run

# Build release APK
flutter build apk --release
```

### Release Signing Configuration (Optional)
By default, release builds run with debug signing for local testing. To produce a production-signed APK:
1. Copy `android/key.properties.example` to `android/key.properties`:
   ```properties
   storePassword=your_keystore_password
   keyPassword=your_key_password
   keyAlias=your_key_alias
   storeFile=/path/to/your/upload-keystore.jks
   ```
2. Build release: `flutter build apk --release`. Gradle will automatically detect `key.properties` and sign the APK with your release key.

---

## ❓ Troubleshooting & FAQs

### Q: I get `FLOOD_WAIT_X` when logging in.
Telegram has rate-limited login code requests for your phone number. Wait the indicated number of seconds before requesting a code again. Do not spam requests.

### Q: My video playback flickers on some devices.
Nuvex includes an integrated Vulkan external texture stabilizer and chunked prefetching to eliminate frame dropping and decoder conflicts.

### Q: Where are my locked files stored?
Encrypted media is held in the app's internal private storage directory (`nuvex_locked`) using AES-256-GCM. Files are named with UUIDs, have an authenticated binary header, and cannot be decrypted without the master key stored in Android KeyStore.

---

## 📄 License

This project is licensed under the terms of the project repository. See the `LICENSE` file for details.
