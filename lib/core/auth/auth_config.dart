/// OAuth configuration, supplied at build time via `--dart-define` (or
/// `--dart-define-from-file=config/oauth.json`) so no client IDs are committed.
///
/// See README.md → "Google Cloud setup" for how to create these values.
class AuthConfig {
  const AuthConfig({
    required this.androidServerClientId,
    required this.desktopClientId,
    required this.desktopClientSecret,
  });

  /// Reads values from compile-time environment declarations.
  const AuthConfig.fromEnvironment()
    : androidServerClientId = const String.fromEnvironment(
        'GOOGLE_SERVER_CLIENT_ID',
      ),
      desktopClientId = const String.fromEnvironment(
        'GOOGLE_DESKTOP_CLIENT_ID',
      ),
      desktopClientSecret = const String.fromEnvironment(
        'GOOGLE_DESKTOP_CLIENT_SECRET',
      );

  /// "Web application" OAuth client ID. Android's Credential Manager requires
  /// it as the `serverClientId` even though ColabMate has no server.
  final String androidServerClientId;

  /// "Desktop app" OAuth client ID used by the Windows loopback flow.
  final String desktopClientId;

  /// "Desktop app" client secret. Google documents that installed-app secrets
  /// are not treated as confidential; it is still kept out of source control.
  final String desktopClientSecret;
}

/// Scopes requested at sign-in.
///
/// Full `drive` scope is needed because ColabMate must list, read and write
/// existing .ipynb files that it did not create (FR-02, FR-06); the narrower
/// `drive.file` scope only covers files created/opened by the app.
const List<String> kGoogleScopes = <String>[
  'openid',
  'email',
  'profile',
  'https://www.googleapis.com/auth/drive',
];

/// Access tokens are refreshed when they have less than this time left.
const Duration kTokenRefreshMargin = Duration(minutes: 5);
