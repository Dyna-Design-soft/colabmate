import 'dart:async';

import 'package:dio/dio.dart';

import '../../models/runtime_status.dart';
import '../auth/auth_exceptions.dart';
import '../auth/auth_interceptor.dart';
import '../auth/auth_manager.dart';

/// OAuth scope for Google's official Colab API.
const List<String> kColabScopes = [
  'https://www.googleapis.com/auth/colaboratory',
];

/// Colab API is unreachable (no network).
class ColabOfflineException implements Exception {
  const ColabOfflineException();
  @override
  String toString() => 'You are offline.';
}

/// Error returned by the Colab API. [reason] is Google's machine-readable
/// error reason (e.g. SERVICE_DISABLED) when present.
class ColabApiException implements Exception {
  const ColabApiException(this.message, {this.status, this.reason});
  final String message;
  final int? status;
  final String? reason;

  @override
  String toString() => message;
}

/// Client for Google's official Colab API (colaboratory.googleapis.com,
/// https://developers.google.com/colab/api) — the same API used by Google's
/// Colab extension for VS Code.
class ColabApi {
  ColabApi({required this._auth, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = 'https://colaboratory.googleapis.com/'
      ..connectTimeout ??= const Duration(seconds: 10)
      ..receiveTimeout ??= const Duration(seconds: 30);
    _dio.interceptors.add(
      BearerAuthInterceptor(
        _dio,
        token: () => _auth.getScopedToken(kColabScopes),
        refresh: () => _auth.getScopedToken(kColabScopes, forceRefresh: true),
      ),
    );
  }

  final AuthManager _auth;
  final Dio _dio;

  /// Asks the user to grant Colab access (shows Google's consent screen if
  /// needed). Throws [ScopeNotGrantedException] if they decline.
  Future<void> grantAccess() =>
      _auth.getScopedToken(kColabScopes, interactive: true);

  /// True if Colab access was granted earlier (no UI shown).
  Future<bool> hasAccess() async {
    try {
      await _auth.getScopedToken(kColabScopes);
      return true;
    } on ScopeNotGrantedException {
      return false;
    }
  }

  Future<SubscriptionTier> getSubscription() async {
    final data = await _get('v1beta/subscription');
    return SubscriptionTier.parse(data['tier']);
  }

  /// Runtime types (CPU / GPU / TPU …) and whether the user may use each.
  Future<List<RuntimeSpecOption>> listRuntimeSpecs() async {
    final data = await _get('v1beta/runtimespecs');
    return [
      for (final s in (data['runtimeSpecs'] as List? ?? const []).cast<Map>())
        RuntimeSpecOption.fromJson(s.cast<String, dynamic>()),
    ];
  }

  /// Runtimes currently assigned to the user.
  Future<List<RuntimeInfo>> listRuntimes() async {
    final data = await _get('v1beta/runtimes');
    return [
      for (final r in (data['runtimes'] as List? ?? const []).cast<Map>())
        RuntimeInfo.fromJson(r.cast<String, dynamic>()),
    ];
  }

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(path);
      return res.data ?? const {};
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  Exception _map(DioException e) {
    final cause = e.error;
    if (cause is AuthNetworkException) return const ColabOfflineException();
    if (cause is AuthException) return cause;
    final res = e.response;
    if (res == null) return const ColabOfflineException();
    final data = res.data;
    final error = data is Map ? data['error'] : null;
    final message = error is Map ? error['message'] as String? : null;
    String? reason;
    if (error is Map && error['details'] is List) {
      for (final d in (error['details'] as List).whereType<Map>()) {
        if (d['reason'] is String) reason = d['reason'] as String;
      }
    }
    final friendly = switch (reason) {
      'SERVICE_DISABLED' =>
        'The Colab API is not enabled in your Google Cloud project. '
            'Enable "Colab API" under APIs & Services → Library, wait a few '
            'minutes and try again.',
      'ACCESS_TOKEN_SCOPE_INSUFFICIENT' =>
        'Colab access was not granted. Tap "Allow Colab access".',
      _ => null,
    };
    return ColabApiException(
      friendly ?? 'Colab API error ${res.statusCode}: ${message ?? data}',
      status: res.statusCode,
      reason: reason,
    );
  }
}
