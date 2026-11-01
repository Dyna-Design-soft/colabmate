import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

import 'auth_backend.dart';
import 'auth_config.dart';
import 'auth_exceptions.dart';
import 'google_oauth_api.dart';
import 'token_storage.dart';

/// Opens [url] in the user's default browser. Injectable for tests.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _launchInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// OAuth 2.0 for installed apps on Windows: opens Google's consent page in the
/// system browser and receives the authorization code on a temporary
/// `http://127.0.0.1:<random port>` listener, protected by PKCE + `state`.
///
/// https://developers.google.com/identity/protocols/oauth2/native-app
class DesktopLoopbackAuthBackend implements AuthBackend {
  DesktopLoopbackAuthBackend({
    required this._config,
    GoogleOAuthApi? api,
    UrlOpener? openUrl,
    DateTime Function()? clock,
    this.timeout = const Duration(minutes: 5),
  }) : _api = api ?? GoogleOAuthApi(),
       _openUrl = openUrl ?? _launchInBrowser,
       _now = clock ?? DateTime.now;

  final AuthConfig _config;
  final GoogleOAuthApi _api;
  final UrlOpener _openUrl;
  final DateTime Function() _now;

  /// How long to wait for the user to finish in the browser.
  final Duration timeout;

  static final Random _random = Random.secure();

  @override
  Future<StoredCredentials> signIn() async {
    if (_config.desktopClientId.isEmpty ||
        _config.desktopClientSecret.isEmpty) {
      throw const AuthConfigException(
        'GOOGLE_DESKTOP_CLIENT_ID / GOOGLE_DESKTOP_CLIENT_SECRET are not '
        'set. See README "Google Cloud setup".',
      );
    }

    final verifier = _randomString(64);
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final state = _randomString(32);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}';
    try {
      final authUrl = Uri.parse(GoogleOAuthApi.authorizationEndpoint).replace(
        queryParameters: {
          'client_id': _config.desktopClientId,
          'redirect_uri': redirectUri,
          'response_type': 'code',
          'scope': kGoogleScopes.join(' '),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
          // Ask for a refresh token so the user stays signed in (test A3).
          'access_type': 'offline',
          'prompt': 'consent select_account',
        },
      );

      final opened = await _openUrl(authUrl);
      if (!opened) {
        throw const AuthUnknownException('Could not open the web browser.');
      }

      final code = await _awaitCode(server, state).timeout(
        timeout,
        onTimeout: () => throw const SignInCancelledException(
          'Timed out waiting for Google sign-in in the browser.',
        ),
      );

      final tokens = await _api.exchangeCode(
        code: code,
        codeVerifier: verifier,
        redirectUri: redirectUri,
        clientId: _config.desktopClientId,
        clientSecret: _config.desktopClientSecret,
      );
      final profile = await _api.userInfo(tokens.accessToken);
      return StoredCredentials(
        accessToken: tokens.accessToken,
        expiresAt: _now().add(tokens.expiresIn),
        refreshToken: tokens.refreshToken,
        profile: profile,
      );
    } finally {
      await server.close(force: true);
    }
  }

  /// Serves the redirect and returns the authorization code.
  Future<String> _awaitCode(HttpServer server, String expectedState) async {
    await for (final request in server) {
      final params = request.uri.queryParameters;
      // Browsers may also request /favicon.ico etc.
      if (!params.containsKey('code') && !params.containsKey('error')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }

      // Google echoes `state` on both success and error redirects. Ignore
      // anything else (stray/replayed requests from other local processes or
      // browser history) and keep waiting for the real redirect.
      if (params['state'] != expectedState) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }

      final error = params['error'];
      await _respond(request, success: error == null);

      if (error == 'access_denied') throw const SignInCancelledException();
      if (error != null) {
        throw AuthUnknownException('Google sign-in error: $error');
      }
      return params['code']!;
    }
    throw const SignInCancelledException();
  }

  Future<void> _respond(HttpRequest request, {required bool success}) async {
    final html = await _redirectPage();
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        html.replaceAll(
          '{{MESSAGE}}',
          success
              ? 'Signed in to ColabMate. You can close this tab and return to the app.'
              : 'Sign-in was not completed. You can close this tab and try again in ColabMate.',
        ),
      );
    await request.response.close();
  }

  Future<String> _redirectPage() async {
    try {
      return await rootBundle.loadString('assets/google_sign_in.html');
    } catch (_) {
      return '<!doctype html><meta charset="utf-8"><title>ColabMate</title>'
          '<p>{{MESSAGE}}</p>';
    }
  }

  @override
  Future<StoredCredentials> refresh(StoredCredentials current) async {
    final refreshToken = current.refreshToken;
    if (refreshToken == null) throw const AuthExpiredException();
    final tokens = await _api.refresh(
      refreshToken: refreshToken,
      clientId: _config.desktopClientId,
      clientSecret: _config.desktopClientSecret,
    );
    return current.copyWith(
      accessToken: tokens.accessToken,
      expiresAt: _now().add(tokens.expiresIn),
      // Google normally omits refresh_token on refresh; keep the old one.
      refreshToken: tokens.refreshToken ?? refreshToken,
    );
  }

  @override
  Future<bool> isAccessTokenValid(String accessToken) =>
      _api.isAccessTokenValid(accessToken);

  @override
  Future<void> signOut(StoredCredentials? current) async {
    final token = current?.refreshToken ?? current?.accessToken;
    if (token != null) await _api.revoke(token);
  }

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(
      length,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
  }
}
