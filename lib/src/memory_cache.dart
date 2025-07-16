import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:http/http.dart';
import 'package:http_cache/src/caching_info.dart';
import 'package:http_cache/src/http_cache.dart';
import 'package:http_cache/src/http_cache_entry.dart';

class MemoryCache extends HttpCache {

  final _entries = <HttpCacheEntry>[];

  @override
  HttpCacheEntry? lookup(BaseRequest request) {
    return _entries.firstWhereOrNull((e) => e.key.url == request.url && e.key.hasMatchingVaryHeaders(request.headers));
  }

  @override
  Future<HttpCacheEntry?> create(BaseRequest request, StreamedResponse response, CachingInfo info) {
    return MemoryCacheEntry.fromResponse(request, response, info);
  }

  @override
  void add(HttpCacheEntry entry) {
    _entries.add(entry);
  }

  @override
  void evict(CacheKey key) {
    _entries.removeWhere((e) => e.key == key);
  }

  @override
  void clear() {
    _entries.clear();
  }
}

class MemoryCacheEntry extends HttpCacheEntry {
  final Uint8List body;

  MemoryCacheEntry(super.key, super.date, super.responseHeaders, super.info, super.reasonPhrase, this.body);

  static Future<HttpCacheEntry?> fromResponse(BaseRequest request, StreamedResponse response, CachingInfo info) async {
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
  StreamedResponse toResponse(BaseRequest request, [StreamedResponse? response]) {
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
}
