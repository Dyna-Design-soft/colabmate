import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/runtime_status.dart';
import 'colab_api.dart';

/// Header carrying the runtime's short-lived proxy token (from the Colab
/// API's `connectionInfo.token`).
const String kColabProxyTokenHeader = 'X-Colab-Runtime-Proxy-Token';

/// Identifies the calling app to Colab's runtime proxy.
const String kColabClientAgentHeader = 'X-Colab-Client-Agent';
const String kColabClientAgent = 'colabmate';

/// A kernel running on the runtime's Jupyter server.
@immutable
class KernelInfo {
  const KernelInfo({
    required this.id,
    required this.name,
    this.executionState,
    this.lastActivity,
  });

  factory KernelInfo.fromJson(Map<String, dynamic> j) => KernelInfo(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'python3',
    executionState: j['execution_state'] as String?,
    lastActivity: DateTime.tryParse(j['last_activity'] as String? ?? ''),
  );

  final String id;
  final String name;
  final String? executionState;
  final DateTime? lastActivity;
}

/// REST calls to a Colab runtime's Jupyter server, through Colab's runtime
/// proxy (spec §4.3 `jupyter_client.dart`). All Colab-specific details live
/// here and in [ColabApi] (Risk 2 mitigation).
class JupyterClient {
  JupyterClient({required Uri baseUrl, required this._token, Dio? dio})
    : _base = baseUrl.path.endsWith('/')
          ? baseUrl
          : baseUrl.replace(path: '${baseUrl.path}/'),
      _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout ??= const Duration(seconds: 15)
      ..receiveTimeout ??= const Duration(seconds: 30);
  }

  final Uri _base;
  final String Function() _token;
  final Dio _dio;

  /// Headers every request (HTTP and WebSocket) to the runtime needs.
  Map<String, String> get headers => {
    kColabProxyTokenHeader: _token(),
    kColabClientAgentHeader: kColabClientAgent,
  };

  Future<List<KernelInfo>> listKernels() async {
    final data = await _request<List<dynamic>>('GET', 'api/kernels');
    return [
      for (final k in data ?? const [])
        if (k is Map) KernelInfo.fromJson(k.cast<String, dynamic>()),
    ];
  }

  Future<KernelInfo> startKernel({String name = 'python3'}) async {
    final data = await _request<Map<String, dynamic>>(
      'POST',
      'api/kernels',
      data: {'name': name},
    );
    return KernelInfo.fromJson(data ?? const {});
  }

  /// Stops the running cell (like Colab's ■ button).
  Future<void> interruptKernel(String id) =>
      _request<Object>('POST', 'api/kernels/$id/interrupt');

  Future<void> restartKernel(String id) =>
      _request<Object>('POST', 'api/kernels/$id/restart');

  /// RAM / disk / GPU usage of the runtime.
  Future<RuntimeResources> getResources() async {
    final data = await _request<Map<String, dynamic>>(
      'GET',
      'api/colab/resources',
    );
    return RuntimeResources.fromJson(data ?? const {});
  }

  /// WebSocket URL for a kernel's message channels.
  Uri channelsUri(String kernelId, {required String sessionId}) {
    final http = _base.resolve('api/kernels/$kernelId/channels');
    return http.replace(
      scheme: http.scheme == 'http' ? 'ws' : 'wss',
      queryParameters: {'session_id': sessionId},
    );
  }

  Future<T?> _request<T>(String method, String path, {Object? data}) async {
    try {
      final res = await _dio.requestUri<T>(
        _base.resolve(path),
        data: data,
        options: Options(method: method, headers: headers),
      );
      return res.data;
    } on DioException catch (e) {
      final res = e.response;
      if (res == null) throw const ColabOfflineException();
      throw ColabApiException(
        'Runtime error ${res.statusCode} on $path: ${res.data}',
        status: res.statusCode,
      );
    }
  }
}
