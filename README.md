# ColabMate

A personal Flutter companion app for Google Colab on **Android** and **Windows**.
It signs in with your Google account and talks directly to Google APIs: no
backend server, no store listing.

The source of truth for scope and build order is the *ColabMate SDLC Handover
Document*. Spec gaps found during implementation are tracked in
[`docs/SPEC_NOTES.md`](docs/SPEC_NOTES.md).

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Project setup, dependencies, folder structure | ✅ Done (Google Cloud / Firebase console steps are manual, see below) |
| 2 | Auth Manager (`token_storage`, `auth_manager`, `auth_provider`, test screen) | ✅ Done. Auth gate A1–A6 passed on Android (2026-11-01) |
| 3 | Drive Manager (`notebook`, `database`, `notebook_cache`, `drive_manager`, `drive_provider`, list + simple editor screens) | ✅ Code + unit tests done. **Waiting on the manual Drive gate test (D1–D6)** |
| 4–8 | Runtime, notifications, UI, offline sync | ⏳ Not started |

## Prerequisites

* Flutter stable (built with 3.47.x / Dart 3.13)
* Android: Android SDK (API 36), a device or emulator with Google Play Services
* Windows: Visual Studio 2022 with the "Desktop development with C++" workload

## Google Cloud setup (one-time, manual)

1. Create a project at <https://console.cloud.google.com>.
2. **APIs & Services → Library**: enable the **Google Drive API**.
3. **Google Auth Platform → Branding / Audience**: create the consent screen.
   Choose *External* and leave it in **Testing**. Add your own Gmail address
   under **Test users**.
   *Note:* while the app is in Testing, Google expires refresh tokens after
   7 days, so expect to sign in again about once a week. See `docs/SPEC_NOTES.md`.
4. **Google Auth Platform → Data access**: add the scopes `openid`, `email`, `profile`,
   `https://www.googleapis.com/auth/drive`.
5. **Clients**: create three OAuth clients:
   | Type | Used for | Notes |
   |---|---|---|
   | **Android** | Android sign-in | Package name `com.dynaspede.colabmate`, SHA-1 from `cd android && ./gradlew signingReport` (debug keystore) |
   | **Web application** | Android `serverClientId` | No redirect URIs needed. Android's Credential Manager requires this ID |
   | **Desktop app** | Windows sign-in | Copy the client ID **and** client secret |
6. Copy `config/oauth.example.json` to `config/oauth.json` and fill in the Web
   client ID and the Desktop client ID and secret. This file is git-ignored.

Firebase/FCM setup (`google-services.json`) is part of Phase 5. It isn't
needed to build or run Phases 1–4.

## Build the APK on GitHub (recommended)

Android is the current focus; Windows builds are paused.

The workflow `.github/workflows/android.yml` runs on every push to `main`,
`dev` or `claude/**` (or manually: **Actions → Android APK → Run workflow**).
It analyzes, runs the tests, builds a signed release APK and publishes it on
the **Releases** page (https://github.com/Dyna-Design-soft/colabmate/releases)
as a plain `.apk` file. Open the latest release on your phone, tap the `.apk`
and install it (allow "Install unknown apps"). Each build has a higher
version code, so it installs over the previous one.

Repository secrets (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Base64 of the release keystore (`base64 -w0 colabmate-release.jks`) |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | `colabmate` |
| `ANDROID_KEY_PASSWORD` | Key password (same as keystore password) |
| `GOOGLE_SERVER_CLIENT_ID` | The **Web application** OAuth client ID |

Register the release key's **SHA-1** on the **Android** OAuth client (package
`com.dynaspede.colabmate`). Get it with
`keytool -list -v -keystore colabmate-release.jks`. Keep the keystore safe:
losing it means a new SHA-1 and reinstalling the app.

Without the secrets the workflow still builds, but signs with a throwaway debug
key and Google sign-in will fail.

## Run locally

```bash
flutter pub get
flutter run -d android  --dart-define-from-file=config/oauth.json
flutter run -d windows  --dart-define-from-file=config/oauth.json
```

Direct-install builds:

```bash
flutter build apk --release --dart-define-from-file=config/oauth.json   # build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release --dart-define-from-file=config/oauth.json # build/windows/x64/runner/Release/
```

## Tests

```bash
flutter analyze
flutter test
```

`test/core/auth_manager_test.dart` covers the AuthManager lifecycle (sign-in,
persistence, auto-refresh, revoked grant, offline restore, sign-out) and the
Windows loopback + PKCE flow against a fake Google token endpoint.

### Drive gate (manual, Android)

| # | Test | Pass condition |
|---|---|---|
| D1 | Sign in, notebook list opens | At least one .ipynb from Drive is listed |
| D2 | Tap a notebook | Cells are visible |
| D3 | Airplane mode on, reopen the app, open that notebook | It loads from the device cache |
| D4 | Still offline: tap a cell, change it, **Save** | "Saved offline" + upload banner / cloud icon shown |
| D5 | Airplane mode off | The edit uploads automatically (banner/icon disappears) |
| D6 | Open the notebook in Colab / Drive web | The change is there |

### Auth gate (manual, on each platform) — passed

| # | Test | Pass condition |
|---|---|---|
| A1 | Tap **Sign in with Google** | Google consent screen appears (browser on Windows) |
| A2 | Complete sign-in | Name + profile photo shown |
| A3 | Close and reopen app | Still signed in |
| A4 | Tap **Sign out** | Name/photo cleared |
| A5 | Sign in again | Works without error |
| A6 | Revoke access at <https://myaccount.google.com/permissions>, reopen app | App returns to sign-in screen ("session expired") |

## How auth works

| Platform | Mechanism | Long-lived grant held by |
|---|---|---|
| Android | `google_sign_in` 7.x (Credential Manager + Play Services authorization) | Google Play Services |
| Windows | System browser → `http://127.0.0.1:<port>` loopback redirect with PKCE (`DesktopLoopbackAuthBackend`). `google_sign_in` has no Windows support | Refresh token in Windows Credential Manager |

The app never sees your Google password (NFR-01). Tokens are stored only through
`flutter_secure_storage` (Android Keystore / Windows Credential Manager, NFR-02).
`AuthManager.getAccessToken()` refreshes the token silently when it has less than
5 minutes left. On startup the token is checked with Google, so access revoked
from your Google account settings is detected (A6). When offline, the stored
session is kept so cached notebooks still open.

## Project layout

Follows §6 of the handover document. Files are added phase by phase, and empty
directories hold a `.gitkeep` until their phase starts. Additions to §6 so far:

* `lib/core/auth/auth_backend.dart`, `google_sign_in_auth_backend.dart`,
  `desktop_loopback_auth_backend.dart`: the per-platform OAuth implementations
* `lib/core/auth/google_oauth_api.dart`: Google token/userinfo/revoke endpoints
* `lib/core/auth/auth_config.dart`, `auth_exceptions.dart`
