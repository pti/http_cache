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

  /// Only return cached responses, or 404 if not found.
  cacheOnly,

  alwaysValidate
}

abstract class HttpCache {
  static GLogger? logger;
  static void setupLogger(LogPrinter? printer) {
    if (printer == null) {
      logger = null;
    } else {
      logger = GLogger(printer);
    }
  }

  /// Active cache operating mode, defaults to [CacheMode.standard].
  var mode = CacheMode.standard;

  /// `cache-control` header to use when the response doesn't define one, defaults to `no-cache`
  /// (store to cache, but always validate).
  var defaultCacheControl = CacheControl.using(noCache: true);

  /// Disable to not include [kHttpHeaderIfNoneMatchHeader] or [kHttpHeaderIfModifiedSinceHeader] headers
  /// in validation requests.
  ///
  /// On the web validation requests seem to fail if enabled. Perhaps because the browser itself has caching
  /// enabled (and it cannot be disabled?). Of course using [HttpCache] on the web shouldn't be needed/used unless
  /// you need to override caching behavior.
  var useValidationHeaders = true;

  /// Used for checking if a request is potentially cacheable. If `false` is returned,
  /// then the cache is bypassed and handled completely with the inner client.
  bool Function(BaseRequest) isRequestCacheable = (req) => req.method == kHttpMethodGet || req.method == kHttpMethodHead;

  /// Used for checking if the response should be stored in cache.
  bool Function(BaseRequest, BaseResponse, CachingInfo) isResponseCacheable = (_, _, info) => info.isCacheable();

  void dispose() {
  }

  /// Lookup a cache entry matching the given request.
  FutureOr<HttpCacheEntry?> lookup(BaseRequest request, [CacheRequestContext? context]);

  /// Creates an entry from the response. Must also add the entry if created successfully.
  /// Returns `null` if the entry cannot be created.
  FutureOr<HttpCacheEntry?> create(BaseRequest request, StreamedResponse response, CachingInfo info, [CacheRequestContext? context]);

  /// Add an entry to cache.
  FutureOr<void> add(HttpCacheEntry entry);

  /// Remove the specified entry from the cache.
  FutureOr<void> evict(CacheKey key, [CacheRequestContext? context]);

  /// Remove all entries from the cache.
  FutureOr<void> clear();

  /// Updates metadata associated with the entry.
  FutureOr<HttpCacheEntry?> update(HttpCacheEntry entry, [Headers? headers, CachingInfo? info, CacheRequestContext? context]);

  /// Cache utilizing entry point / interceptor for sending HTTP requests.
  Future<StreamedResponse> send(BaseRequest request, Client inner) async {
    final mode = _getMode(request);

    if (!isRequestCacheable(request) && mode != CacheMode.cacheOnly) {
      _log('send: not cacheable');
      return inner.send(request);
    }

    final ctx = createRequestContext(request);
    ctx.mode = mode;
    HttpCacheEntry? entry;

    try {
      final instruction = await _check(request, ctx);

      if (instruction != null) {
        entry = instruction.entry;

        if (instruction.validate) {
          _log('send: validate');
          request.headers.addAll(instruction.headers ?? {});

        } else {
          _log('send: from cache');
          return _toResponse(entry, request, null, ctx);
        }

      } else if (mode == CacheMode.cacheOnly) {
        ctx.onRequestCompleted(null);
        return StreamedResponse(Stream.empty(), kHttpStatusNotFound);
      }

    } catch (err, st) {
      _log('send: failed to read cache entry - ignoring cache completely', err, st);
      ctx.onRequestCompleted(err);
      return inner.send(request);
    }

    Object? error;

    try {
      final response = await inner.send(request);
      _log('send: got response ${response.statusCode} (${response.headers[kHttpHeaderCacheControl]})');
      return await _handleResponse(request, response, entry, ctx);

    } catch (err, st) {
      _log('send: error sending or handling response ${request.url}', err, st);
      error = err;

      if (entry != null && mode == CacheMode.cachedOnError) {
        return _toResponse(entry, request, null, ctx);
      } else {
        rethrow;
      }

    } finally {
      ctx.onRequestCompleted(error);
    }
  }

  /// Does a lookup and creates instructions based on the current state of the entry, i.e.
  /// specifies whether validation is needed or not.
  FutureOr<_CacheInstruction?> _check(BaseRequest request, CacheRequestContext context) async {
    final entry = await lookup(request, context);

    if (entry == null) {
      return null;
    }

    Headers? headers;
    final validate = switch (context.mode) {
      CacheMode.preferCached => false,
      CacheMode.alwaysValidate => true,
      CacheMode.cacheOnly => false,
      CacheMode.standard || CacheMode.cachedOnError => entry.info.shouldValidate(),
    };

    if (validate && useValidationHeaders) {
      headers = {
        kHttpHeaderIfNoneMatchHeader: ?entry.responseHeaders[kHttpHeaderETag],
        kHttpHeaderIfModifiedSinceHeader: ?entry.responseHeaders[kHttpHeaderLastModifiedHeader],
      };
    }

    return _CacheInstruction(entry, validate, headers);
  }

  CacheMode _getMode(BaseRequest request) => (request is CacheableRequest ? request.mode : null) ?? mode;

  Future<StreamedResponse> _handleResponse(BaseRequest request, StreamedResponse response, HttpCacheEntry? entry, CacheRequestContext context) async {
    final notModified = response.statusCode == kHttpStatusNotModified && entry != null;
    final statusCode = notModified ? kHttpStatusOk : response.statusCode;
    final info = CachingInfo.fromResponse(request, statusCode, response.headers, defaultCacheControl);

    if (notModified) {
      // Return the response from the cache.
      // Update the entry in case headers changed (e.g. date or expires → update CachingInfo.expires).
      // The 304 response might not contain all of the headers (e.g. content-type / length) so instead simply replacing
      // the headers, override existing values with new ones.
      final mergedHeaders = <String, String>{};
      mergedHeaders.addAll(entry.responseHeaders);
      mergedHeaders.addAll(response.headers);
      final updated = await update(entry, mergedHeaders, info, context);
      return _toResponse(updated ?? entry, request, response, context);
    }

    if (!isResponseCacheable(request, response, info)) {
      _log('not cacheable, ${request.url}');
      return response;
    }

    if (entry != null) {
      _log('got response ${response.statusCode}, evict entry before creating the replacement, ${entry.key.url}');
      await evict(entry.key, context);
    }

    // Store the response to the cache.
    final fresh = await create(request, response, info, context);

    if (fresh == null) {
      return response;
    }

    return _toResponse(fresh, request, response, context);
  }

  CacheRequestContext createRequestContext(BaseRequest request) => CacheRequestContext(request);

  StreamedResponse _toResponse(HttpCacheEntry entry, BaseRequest request, StreamedResponse? response, CacheRequestContext context) {
    if (request is CacheableRequest && request.useNotModified == true) {
      final entryEtag = entry.responseHeaders[kHttpHeaderETag];
      final requestEtag = request.headers[kHttpHeaderIfNoneMatchHeader];

      if (response != null && response.statusCode == kHttpStatusNotModified) {
        return response;

      } else if (response == null && entryEtag == requestEtag) {
        // TODO last modified support too
        // This case is used for cases where no validation is needed.
        final headers = Map.of(entry.responseHeaders);
        headers.remove(kHttpHeaderContentLength);
        headers.remove(kHttpHeaderContentType);
        context.onRequestCompleted(null);
        return StreamedResponse(Stream.empty(), kHttpStatusNotModified, headers: headers);
      }
    }

    return entry.toResponse(request, response, context);
  }

  void _log(String msg, [Object? err, StackTrace? stackTrace]) => logger?.log(msg, err, stackTrace);
}

class _CacheInstruction {
  final bool validate;
  final HttpCacheEntry entry;

  /// Additional request headers required to revalidate the entry.
  final Headers? headers;

  _CacheInstruction(this.entry, this.validate, this.headers);
}

class CacheRequestContext {
  final BaseRequest request;
  var mode = CacheMode.standard;

  CacheRequestContext(this.request);

  void onRequestCompleted(Object? err) {
  }
}
