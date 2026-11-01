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

  /// One runtime, with fresh connection info (the proxy token is
  /// short-lived; call this again when it nears [RuntimeConnection.expireTime]).
  Future<RuntimeInfo> getRuntime(String name) async =>
      RuntimeInfo.fromJson(await _get('v1beta/$name'));

  /// Starts a new runtime of type [spec] (e.g. T4 GPU). Waits for Colab to
  /// assign the machine, which can take a minute.
  Future<RuntimeInfo> createRuntime(
    RuntimeSpecKey spec, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    var op = await _send(
      'POST',
      'v1beta/runtimes',
      data: {'runtimeSpec': spec.toJson()},
    );
    final deadline = DateTime.now().add(timeout);
    while (op['done'] != true) {
      final name = op['name'] as String?;
      if (name == null) {
        throw const ColabApiException('Colab did not return an operation.');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const ColabApiException(
          'Timed out waiting for Colab to start the runtime.',
        );
      }
      // Long-poll: returns when done or after ~30 s.
      op = await _send('GET', 'v1/$name:wait', query: {'timeout': '30s'});
    }
    final error = op['error'];
    if (error is Map) {
      throw ColabApiException(
        _runtimeErrorMessage(error, spec),
        status: (error['code'] as num?)?.toInt(),
      );
    }
    final response = (op['response'] as Map?)?.cast<String, dynamic>();
    if (response == null) {
      throw const ColabApiException('Colab returned no runtime.');
    }
    final runtime = RuntimeInfo.fromJson(response);
    // The create response may omit connection info; fetch it.
    return runtime.connection == null ? getRuntime(runtime.name) : runtime;
  }

  /// Stops (releases) a runtime. Anything running on it is lost.
  Future<void> deleteRuntime(String name) =>
      _send('DELETE', 'v1beta/$name', query: {'allowMissing': 'true'});

  /// Compute-unit usage. Uses Colab's own user-info endpoint, which may not
  /// accept third-party apps — returns null instead of failing then.
  Future<ColabUsage?> getUsage() async {
    try {
      final data = await _send(
        'GET',
        'https://colab.pa.googleapis.com/v1/user-info',
        query: {'get_ccu_consumption_info': 'true'},
      );
      return ColabUsage.fromJson(data);
    } catch (e) {
      // Optional feature: hide the usage card on any failure.
      return null;
    }
  }

  static String _runtimeErrorMessage(Map error, RuntimeSpecKey spec) {
    final message = error['message'] as String? ?? 'Unknown error';
    final text = message.toLowerCase();
    if (text.contains('unavailable') || text.contains('resource_exhausted')) {
      return '${spec.label} is not available right now (Colab may be out of '
          'free GPUs, or you hit a usage limit). Try again later or pick CPU.';
    }
    if (text.contains('too many')) {
      return 'You already have the maximum number of runtimes. Stop one first.';
    }
    return 'Could not start ${spec.label}: $message';
  }

  Future<Map<String, dynamic>> _get(String path) => _send('GET', path);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? data,
    Map<String, String>? query,
  }) async {
    try {
      final res = await _dio.request<Map<String, dynamic>>(
        path,
        data: data,
        queryParameters: query,
        options: Options(method: method),
      );
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
