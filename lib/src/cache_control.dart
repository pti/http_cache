import 'package:http_cache/src/util/helpers.dart';
import 'package:http_cache/src/util/http_constants.dart';

class CacheControl {

  static const kMaxAge = 'max-age';
  static const kNoStore = 'no-store';
  static const kNoCache = 'no-cache';

  final Map<String, Object> directives;

  CacheControl(this.directives);

  CacheControl.using({Duration? maxAge, bool? noStore, bool? noCache}): this(Map.unmodifiable({
    kMaxAge: ?maxAge?.inSeconds,
    kNoStore: ?noStore,
    kNoCache: ?noCache,
  }));

  int? get maxAge => directives[kMaxAge] as int?;
  bool get noStore => directives.containsKey(kNoStore);
  bool get noCache => directives.containsKey(kNoCache);

  static CacheControl? fromHeaders(Headers headers) {
    final cacheControl = headers[kHttpHeaderCacheControl];

    if (cacheControl == null) {
      return null;
    }

    final directives = <String, Object>{};

    for (final e in cacheControl.split(',')) {
      var directive = e.trim();
      final separator = directive.indexOf('=');
      Object? value;

      if (separator == -1 || separator == directive.length - 1) {
        value = true;
      } else {
        final v = directive.substring(separator + 1);
        final number = v.tryParseInt();
        value = number ?? v;
        directive = directive.substring(0, separator);
      }

      directives[directive] = value;
    }

    return CacheControl(directives);
  }
}
