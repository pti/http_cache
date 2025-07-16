import 'dart:async';

import 'package:http/http.dart';
import 'package:http_cache/http_cache.dart';
import 'package:http_cache/src/util/glogger.dart';
import 'package:http_cache/src/util/http_constants.dart';

enum CacheMode {
  /// Operate the cache normally, validating when needed.
  standard,

  /// If response is found from cache, then skip validation.
  preferCached,

  /// If request fails, then return the cached response if found.
  cachedOnError,

  alwaysValidate
}

abstract class HttpCache {
  static GLogger? logger;
  static void setupLogger(LogPrinter? printer) {
    if (printer == null) {
      logger = null;
    } else {
      logger = GLogger(printer: printer);
    }
  }

  /// Active cache operating mode, defaults to [CacheMode.standard].
  var mode = CacheMode.standard;

  /// `cache-control` header to use when the response doesn't define one, defaults to `no-cache`
  /// (store to cache, but always validate).
  var defaultCacheControl = CacheControl.using(noCache: true);

  /// Lookup a cache entry matching the given request.
  FutureOr<HttpCacheEntry?> lookup(BaseRequest request);

  /// Creates an entry from the response.
  /// Returns `null` if the entry cannot be created.
  FutureOr<HttpCacheEntry?> create(BaseRequest request, StreamedResponse response, CachingInfo info);

  /// Add an entry to cache. Called after [create].
  FutureOr<void> add(HttpCacheEntry entry);

  /// Remove the specified entry from the cache.
  FutureOr<void> evict(CacheKey key);

  /// Remove all entries from the cache.
  FutureOr<void> clear();

  /// Cache utilizing entry point / interceptor for sending HTTP requests.
  Future<StreamedResponse> send(BaseRequest request, Client inner) async {

    if (!request.isCacheable) {
      _log('not cacheable');
      return inner.send(request);
    }

    final instruction = await _check(request);
    HttpCacheEntry? entry;

    if (instruction != null) {
      if (instruction.needsValidation) {
        _log('validate');
        request.headers.addAll(instruction.headers ?? {});
        entry = instruction.entry;

      } else {
        _log('from cache');
        return instruction.entry.toResponse(request);
      }

    } else {
      _log('not found');
    }

    try {
      var response = await inner.send(request);
      _log('got response ${response.statusCode}');
      response = await _handleResponse(request, response, entry);
      return response;

    } catch (_) {
      if (entry != null && _getMode(request) == CacheMode.cachedOnError) {
        return entry.toResponse(request);
      } else {
        rethrow;
      }
    }
  }

  /// Does a lookup and creates instructions based on the current state of the entry, i.e.
  /// specifies whether validation is needed or not.
  FutureOr<_CacheInstruction?> _check(BaseRequest request) async {
    final entry = await lookup(request);

    if (entry == null) {
      return null;
    }

    Headers? headers;
    final mode = _getMode(request);
    final validate = switch (mode) {
      CacheMode.preferCached => false,
      CacheMode.alwaysValidate => true,
      _ => entry.info.shouldValidate(),
    };

    if (validate) {
      headers = {
        kHttpHeaderIfNoneMatchHeader: ?entry.responseHeaders[kHttpHeaderETag],
        kHttpHeaderIfModifiedSinceHeader: ?entry.responseHeaders[kHttpHeaderLastModifiedHeader],
      };
    }

    return _CacheInstruction(entry, headers);
  }

  CacheMode _getMode(BaseRequest request) => (request is CacheableRequest ? request.mode : null) ?? mode;

  Future<StreamedResponse> _handleResponse(BaseRequest request, StreamedResponse response, HttpCacheEntry? entry) async {

    if (response.statusCode == kHttpStatusNotModified && entry != null) {
      // Return the response from the cache.
      return entry.toResponse(request, response);
    }

    if (entry != null) {
      await evict(entry.key);
    }

    final info = CachingInfo.fromResponse(request, response.statusCode, response.headers, defaultCacheControl);

    if (!info.isCacheable()) {
      _log('not cacheable');
      return response;
    }

    // Store the response to the cache.
    final fresh = await create(request, response, info);

    if (fresh == null) {
      return response;
    }

    await add(fresh);
    return fresh.toResponse(request, response);
  }

  void _log(String msg) => logger?.log(msg);
}

class _CacheInstruction {
  final HttpCacheEntry entry;

  /// Additional request headers required to revalidate the entry.
  /// Value is `null` if no revalidation is needed.
  final Headers? headers;

  _CacheInstruction(this.entry, this.headers);

  bool get needsValidation => headers != null;
}

extension on BaseRequest {
  bool get isCacheable => method == kHttpMethodGet;
}
