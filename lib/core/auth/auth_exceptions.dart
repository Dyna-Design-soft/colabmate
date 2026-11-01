/// Errors raised by the auth layer. UI code should only need to handle these.
sealed class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// No user is signed in (never signed in, or signed out).
class NotSignedInException extends AuthException {
  const NotSignedInException([super.message = 'Not signed in']);
}

/// The user closed the consent screen / account picker.
class SignInCancelledException extends AuthException {
  const SignInCancelledException([super.message = 'Sign-in was cancelled']);
}

/// The stored grant can no longer be refreshed (expired or revoked from the
/// Google account settings). The user must sign in again.
class AuthExpiredException extends AuthException {
  const AuthExpiredException([
    super.message = 'Your Google session expired. Please sign in again.',
  ]);
}

/// Network failure while talking to Google.
class AuthNetworkException extends AuthException {
  const AuthNetworkException([super.message = 'Network error during sign-in']);
}

/// An extra permission (e.g. Colab) hasn't been granted yet.
class ScopeNotGrantedException extends AuthException {
  const ScopeNotGrantedException([
    super.message = 'This permission has not been granted yet.',
  ]);
}

/// Missing or invalid OAuth client configuration (see README).
class AuthConfigException extends AuthException {
  const AuthConfigException(super.message);
}

/// Anything else reported by the platform sign-in SDK.
class AuthUnknownException extends AuthException {
  const AuthUnknownException(super.message);
}
