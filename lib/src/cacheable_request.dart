import 'package:http/http.dart';
import 'package:http_cache/src/cache_control.dart';
import 'package:http_cache/src/http_cache.dart';

class CacheableRequest extends Request {

  /// Mode applied to this request. If not defined, then use the cache's global mode.
  final CacheMode? mode;

  /// If defined, used for overriding the cache directives of the received response.
  final CacheControl? control;

  CacheableRequest(super.method, super.url, {this.mode, this.control});

  CacheableRequest.get(Uri url, {this.mode, this.control}): super('GET', url);
}
