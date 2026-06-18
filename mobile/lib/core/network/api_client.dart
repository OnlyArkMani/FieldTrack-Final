import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../storage/token_storage.dart';
import 'api_exceptions.dart';

/// Bumped whenever the session dies (refresh failed / revoked). The auth
/// provider listens to this — decoupled so api_client never imports features.
final sessionRevokedProvider = StateProvider<int>((ref) => 0);

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    tokenStorage: ref.watch(tokenStorageProvider),
    onSessionRevoked: () =>
        ref.read(sessionRevokedProvider.notifier).state++,
  );
});

class ApiClient {
  ApiClient({
    required TokenStorage tokenStorage,
    required void Function() onSessionRevoked,
    Dio? dio, // injectable for tests
  })  : _tokens = tokenStorage,
        _onSessionRevoked = onSessionRevoked {
    _dio = dio ??
        Dio(BaseOptions(
          baseUrl: Env.apiBaseUrl,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 20),
          headers: {'Accept': 'application/json'},
        ));

    _dio.interceptors.addAll([
      _ConnectivityInterceptor(),
      _AuthInterceptor(_tokens),
      _RefreshInterceptor(this),
    ]);
  }

  late final Dio _dio;
  final TokenStorage _tokens;
  final void Function() _onSessionRevoked;

  /// Single-flight refresh: concurrent 401s share one refresh call instead
  /// of racing (a race would rotate the token twice and trip the backend's
  /// reuse detection, nuking the session).
  Completer<bool>? _refreshing;

  Dio get dio => _dio;

  // ── Public API: always throws ApiException, never DioException ────────
  Future<Map<String, dynamic>> get(String path,
      {Map<String, dynamic>? query}) async {
    return _run(() => _dio.get(path, queryParameters: query));
  }

  Future<Map<String, dynamic>> post(String path, {Object? body}) async {
    return _run(() => _dio.post(path, data: body));
  }

  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    return _run(() => _dio.put(path, data: body));
  }

  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    return _run(() => _dio.patch(path, data: body));
  }

  /// For endpoints whose top-level body is a JSON array (e.g. GET /teams).
  Future<List<dynamic>> getList(String path,
      {Map<String, dynamic>? query}) async {
    try {
      final response = await _dio.get(path, queryParameters: query);
      final data = response.data;
      return data is List ? data : <dynamic>[];
    } on DioException catch (e) {
      throw mapError(e);
    }
  }

  Future<Map<String, dynamic>> delete(String path) async {
    return _run(() => _dio.delete(path));
  }

  Future<Map<String, dynamic>> _run(
      Future<Response<dynamic>> Function() request) async {
    try {
      final response = await request();
      final data = response.data;
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on DioException catch (e) {
      throw mapError(e);
    }
  }

  // ── Refresh flow ───────────────────────────────────────────────────────
  Future<bool> refreshSession() async {
    // Join an in-flight refresh if one exists.
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight.future;

    final completer = Completer<bool>();
    _refreshing = completer;
    try {
      final refresh = _tokens.refreshToken;
      if (refresh == null) {
        completer.complete(false);
        return false;
      }
      // Bare Dio: MUST NOT go through our interceptors (would recurse).
      final bare = Dio(BaseOptions(baseUrl: Env.apiBaseUrl));
      final response = await bare.post(
        '/auth/refresh',
        options: Options(headers: {'X-Refresh-Token': refresh}),
      );
      final data = response.data as Map<String, dynamic>;
      await _tokens.save(
        access: data['access_token'] as String,
        refresh: data['refresh_token'] as String,
      );
      completer.complete(true);
      return true;
    } catch (_) {
      await forceLogout();
      completer.complete(false);
      return false;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> forceLogout() async {
    await _tokens.clear();
    _onSessionRevoked();
  }

  // ── DioException -> ApiException ───────────────────────────────────────
  static ApiException mapError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return const TimeoutException();
      case DioExceptionType.connectionError:
        return const NoConnectionException();
      default:
        break;
    }

    final response = e.response;
    if (response == null) {
      return const UnknownApiException('Network error', 'NETWORK_ERROR');
    }

    final body = response.data;
    final detail = (body is Map && body['detail'] is String)
        ? body['detail'] as String
        : 'Request failed';
    final code = (body is Map && body['code'] is String)
        ? body['code'] as String
        : 'ERROR';

    switch (response.statusCode ?? 0) {
      case 401:
        return UnauthorizedException(detail, code);
      case 403:
        return ForbiddenException(detail);
      case 422:
        return ValidationException(detail);
      case 429:
        final retryAfter =
            int.tryParse(response.headers.value('retry-after') ?? '');
        return RateLimitedException(detail, retryAfter);
      case >= 500:
        return const ServerException();
      default:
        return UnknownApiException(detail, code);
    }
  }
}

// ── Interceptors ──────────────────────────────────────────────────────────

class _ConnectivityInterceptor extends Interceptor {
  @override
  Future<void> onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    // connectivity_plus's web implementation (navigator.onLine) is unreliable
    // in dev/iframe contexts and can spuriously report "none" while the API
    // is perfectly reachable — blocking every request with a false
    // NoConnectionException. On web we skip this pre-flight check entirely
    // and let an actual failed request surface as DioExceptionType
    // .connectionError (still mapped to NoConnectionException below).
    if (kIsWeb) {
      return handler.next(options);
    }
    final result = await Connectivity().checkConnectivity();
    if (result.contains(ConnectivityResult.none)) {
      return handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: const NoConnectionException(),
        ),
      );
    }
    handler.next(options);
  }
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._tokens);
  final TokenStorage _tokens;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = _tokens.accessToken;
    if (token != null && options.headers['Authorization'] == null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }
}

class _RefreshInterceptor extends Interceptor {
  _RefreshInterceptor(this._client);
  final ApiClient _client;

  static const _kRetried = 'retried_after_refresh';

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    final isAuthEndpoint =
        err.requestOptions.path.startsWith('/auth/login') ||
            err.requestOptions.path.startsWith('/auth/refresh');

    if (response?.statusCode != 401 || isAuthEndpoint) {
      return handler.next(err);
    }

    // Second 401 on the same request => refresh didn't help. Log out.
    if (err.requestOptions.extra[_kRetried] == true) {
      await _client.forceLogout();
      return handler.next(err);
    }

    final refreshed = await _client.refreshSession();
    if (!refreshed) return handler.next(err); // forceLogout already ran

    // Replay the original request once with the new token.
    final opts = err.requestOptions;
    opts.extra[_kRetried] = true;
    opts.headers['Authorization'] =
        'Bearer ${_client._tokens.accessToken}';
    try {
      final retried = await _client.dio.fetch<dynamic>(opts);
      return handler.resolve(retried);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) await _client.forceLogout();
      return handler.next(e);
    }
  }
}
