import 'package:http/http.dart';
import 'package:http_cache/src/cache_control.dart';
import 'package:http_cache/src/http_cache.dart';
import 'package:http_cache/src/util/helpers.dart';
import 'package:http_cache/src/util/http_constants.dart';

class CacheableRequest extends Request {

  /// Mode applied to this request. If not defined, then use the cache's global mode.
  final CacheMode? mode;

  /// If defined, used for overriding the cache directives of the received response.
  final CacheControl? control;

  /// If `true`, response is cached and not modified, then respond with a 304 without the body.
  /// For now properly works only with ETags.
  final bool? useNotModified;

  CacheableRequest(super.method, super.url, {this.mode, this.control, this.useNotModified});

  CacheableRequest.get(Uri url, {this.mode, this.control, this.useNotModified}): super(kHttpMethodGet, url);
  CacheableRequest.head(Uri url, {this.mode, this.control, this.useNotModified}): super(kHttpMethodHead, url);
}

extension HttpCacheStream<T> on Stream<T> {
  Future<void> notifyDone() => take(0).length.tryResult();
}
