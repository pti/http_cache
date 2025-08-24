import 'package:http_cache/src/util/helpers.dart';
import 'package:http_cache/src/util/http_constants.dart';

class CacheControl {

  static const kMaxAge = 'max-age';
  static const kNoStore = 'no-store';
  static const kNoCache = 'no-cache';

  /// Custom directive that can be used to ensure freshness for at least the specified duration.
  /// More specific in cases where response date+age+max-age result in determining that the response is already stale.
  static const kMinFresh = 'min-fresh';

  final Map<String, Object> directives;

  CacheControl(Map<String, Object> directives): directives = Map.unmodifiable(directives);

  CacheControl.using({Duration? maxAge, bool? noStore, bool? noCache, Duration? minFresh}): this({
    kMaxAge: ?maxAge?.inSeconds,
    kNoStore: ?noStore,
    kNoCache: ?noCache,
    kMinFresh: ?minFresh?.inSeconds,
  });

  CacheControl override(CacheControl other) => CacheControl(Map.of(directives)..addAll(other.directives));

  Duration? get maxAge => _getDuration(kMaxAge);

  Duration? get minFresh => _getDuration(kMinFresh);

  Duration? _getDuration(String directive) {
    final value = directives[directive];

    if (directive == kMaxAge && value == null) {
      print(directives);
    }

    return value is int ? Duration(seconds: value) : null;
  }

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
