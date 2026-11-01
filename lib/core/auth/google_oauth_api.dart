import 'package:dio/dio.dart';

import '../../models/user_profile.dart';
import 'auth_exceptions.dart';

/// Response from Google's OAuth token endpoint.
class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    required this.expiresIn,
    this.refreshToken,
  });

  final String accessToken;
  final Duration expiresIn;
  final String? refreshToken;
}

/// Thin wrapper over Google's OAuth 2.0 / OpenID Connect REST endpoints.
class GoogleOAuthApi {
  GoogleOAuthApi([Dio? dio]) : _dio = dio ?? Dio();

  static const String authorizationEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const String tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const String revokeEndpoint = 'https://oauth2.googleapis.com/revoke';
  static const String tokenInfoEndpoint =
      'https://oauth2.googleapis.com/tokeninfo';
  static const String userInfoEndpoint =
      'https://openidconnect.googleapis.com/v1/userinfo';

  final Dio _dio;

  static final Options _form = Options(
    contentType: Headers.formUrlEncodedContentType,
    responseType: ResponseType.json,
  );

  Future<TokenResponse> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
    required String clientId,
    required String clientSecret,
  }) => _token({
    'grant_type': 'authorization_code',
    'code': code,
    'code_verifier': codeVerifier,
    'redirect_uri': redirectUri,
    'client_id': clientId,
    'client_secret': clientSecret,
  });

  Future<TokenResponse> refresh({
    required String refreshToken,
    required String clientId,
    required String clientSecret,
  }) => _token({
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': clientId,
    'client_secret': clientSecret,
  });

  Future<TokenResponse> _token(Map<String, String> body) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        tokenEndpoint,
        data: body,
        options: _form,
      );
      final data = res.data!;
      return TokenResponse(
        accessToken: data['access_token'] as String,
        expiresIn: Duration(seconds: (data['expires_in'] as num).toInt()),
        refreshToken: data['refresh_token'] as String?,
      );
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  Future<UserProfile> userInfo(String accessToken) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        userInfoEndpoint,
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
      final d = res.data!;
      return UserProfile(
        id: d['sub'] as String,
        email: d['email'] as String,
        name: d['name'] as String?,
        photoUrl: d['picture'] as String?,
      );
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  /// True if Google still accepts [accessToken].
  Future<bool> isAccessTokenValid(String accessToken) async {
    try {
      await _dio.get<Object>(
        tokenInfoEndpoint,
        queryParameters: {'access_token': accessToken},
      );
      return true;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400 || status == 401) return false;
      throw _map(e);
    }
  }

  /// Revokes a refresh or access token. Errors are swallowed: revocation is
  /// best effort and local credentials are cleared regardless.
  Future<void> revoke(String token) async {
    try {
      await _dio.post<Object>(
        revokeEndpoint,
        data: {'token': token},
        options: _form,
      );
    } on DioException {
      // ignore
    }
  }

  AuthException _map(DioException e) {
    final res = e.response;
    if (res == null) return const AuthNetworkException();
    final data = res.data;
    final error = data is Map ? data['error'] : null;
    if (error == 'invalid_grant' || res.statusCode == 401) {
      return const AuthExpiredException();
    }
    if (error == 'invalid_client' || error == 'unauthorized_client') {
      return AuthConfigException(
        'Google rejected the OAuth client ($error). Check the client ID '
        'and secret passed via --dart-define.',
      );
    }
    return AuthUnknownException(
      'Google OAuth error ${res.statusCode}: ${error ?? data}',
    );
  }
}
