import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:http/http.dart';
import 'package:http_cache/src/caching_info.dart';
import 'package:http_cache/src/http_cache.dart';
import 'package:http_cache/src/http_cache_entry.dart';
import 'package:http_cache/src/util/http_constants.dart';

class MemoryCache extends HttpCache {

  final _entries = <MemoryCacheEntry>[];

  @override
  HttpCacheEntry? lookup(BaseRequest request, [CacheRequestContext? context]) {
    return _entries.firstWhereOrNull((e) => e.key.isMatching(request.url, request.headers));
  }

  @override
  Future<HttpCacheEntry?> create(BaseRequest request, StreamedResponse response, CachingInfo info, [CacheRequestContext? context]) async {
    final entry = await MemoryCacheEntry.fromResponse(request, response, info);

    if (entry != null) {
      add(entry);
    }

    return entry;
  }

  @override
  void add(covariant MemoryCacheEntry entry) {
    _entries.add(entry);
  }

  @override
  HttpCacheEntry? update(covariant MemoryCacheEntry entry, Headers headers, [CacheRequestContext? context]) {
    final index = _entries.indexWhere((e) => e == entry);

    if (index == -1) {
      return null;
    }

    final updated = _entries[index].updateWith(headers);
    _entries[index] = updated;
    return updated;
  }

  @override
  void evict(CacheKey key, [CacheRequestContext? context]) {
    _entries.removeWhere((e) => e.key == key);
  }

  @override
  void clear() {
    _entries.clear();
  }
}

class MemoryCacheEntry extends HttpCacheEntry {
  final Uint8List body;

  MemoryCacheEntry(super.key, super.date, super.info, super.reasonPhrase, super.responseHeaders, this.body);

  static Future<MemoryCacheEntry?> fromResponse(BaseRequest request, StreamedResponse response, CachingInfo info) async {
    // TODO check if response length > size
    final meta = CacheEntryMeta.fromResponse(request, response, info);
    final body = await response.stream.toBytes();
    return MemoryCacheEntry(
      meta.key,
      meta.date,
      meta.info,
      meta.reasonPhrase,
      meta.responseHeaders,
      body,
    );
  }

  @override
  StreamedResponse toResponse(BaseRequest request, [StreamedResponse? response, CacheRequestContext? context]) {
    return StreamedResponse(
      Stream.value(body),
      info.statusCode,
      request: request,
      persistentConnection: response?.persistentConnection ?? false,
      reasonPhrase: reasonPhrase,
      isRedirect: response?.isRedirect ?? false,
      headers: responseHeaders,
    );
  }

  MemoryCacheEntry updateWith(Headers headers) {
    return MemoryCacheEntry(key, headers.readDate(), info.withHeaders(headers), reasonPhrase, headers, body);
  }
}
