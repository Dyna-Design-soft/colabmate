import 'package:dio/dio.dart';

/// Adds `Authorization: Bearer <token>` to every request and retries once
/// after a 401 with a freshly refreshed token.
///
/// Token errors (e.g. `AuthExpiredException`) are passed on as the
/// [DioException.error] so callers can tell "sign in again" from "offline".
/// A plain (non-queued) interceptor: AuthManager already de-duplicates
/// concurrent refreshes, and this can't deadlock when a retry fails too.
class BearerAuthInterceptor extends Interceptor {
  BearerAuthInterceptor(
    this._dio, {
    required this._token,
    required this._refresh,
  });

  final Dio _dio;
  final Future<String> Function() _token;
  final Future<String> Function() _refresh;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      options.headers['Authorization'] = 'Bearer ${await _token()}';
      handler.next(options);
    } catch (e) {
      handler.reject(DioException(requestOptions: options, error: e));
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    if (err.response?.statusCode != 401 || options.extra['retried'] == true) {
      return handler.next(err);
    }
    try {
      final token = await _refresh();
      options
        ..headers['Authorization'] = 'Bearer $token'
        ..extra['retried'] = true;
      handler.resolve(await _dio.fetch<Object?>(options));
    } on DioException catch (e) {
      handler.next(e);
    } catch (e) {
      // Refresh failed (e.g. access revoked → AuthExpiredException): report
      // that, not the original 401, so the app can ask to sign in again.
      handler.next(
        DioException(requestOptions: options, response: err.response, error: e),
      );
    }
  }
}
