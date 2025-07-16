import 'dart:io';

import 'package:http/io_client.dart';
import 'package:http_cache/http_cache.dart';
import 'package:http_cache/src/util/glogger.dart';

Future<void> main() async {
  final l = GLogger();
  HttpCache.logger = l;
  final url = Uri.parse('https://storage.googleapis.com/cms-storage-bucket/images/flutter_logo.width-635.png');
  final client = IOClient();

  final dir = Directory('.http_cache');
  l.log('Using ${dir.absolute.toString()} as the cache directory');

  final cache = FileCache(dir);
  // cache.defaultCacheControl = CacheControl.using(maxAge: const Duration(minutes: 1));
  await cache.clear();

  final cc = CachingClient(client, cache);

  try {
    final resp = await cc.get(url);
    l.log('--- 1. got ${resp.statusCode} ${resp.contentLength}B');

    // max-age should be 3600s so the next response should get served from the cache directly.
    final resp2 = await cc.get(url);
    l.log('--- 2. got ${resp2.statusCode} ${resp2.contentLength}B');

    // Use CacheMode.alwaysValidate to force validating.
    final resp2b = await cc.send(CacheableRequest('GET', url, mode: CacheMode.alwaysValidate));
    l.log('--- 2b. got ${resp2b.statusCode} ${resp2b.contentLength}B');

    // Override the cache-control for the next response to demonstrate validating.
    await cache.evict(CacheKey(url));
    final resp3 = await cc.send(CacheableRequest('GET', url, control: CacheControl.using(maxAge: const Duration(seconds: 1))));
    l.log('--- 3. got ${resp3.statusCode} ${resp3.contentLength}B');

    // Since 1s has elapsed, validation is needed for the next request.
    await Future<void>.delayed(const Duration(seconds: 2));
    final resp4 = await cc.get(url);
    l.log('--- 4. got ${resp4.statusCode} ${resp4.contentLength}B');

    // preferCached can be used to skip validating. It can also be set globally in cache.mode
    await Future<void>.delayed(const Duration(seconds: 2));
    final resp5 = await cc.send(CacheableRequest('GET', url, mode: CacheMode.preferCached));
    l.log('--- 5. got ${resp5.statusCode} ${resp5.contentLength}B');

  } finally {
    cc.close();
  }
}
