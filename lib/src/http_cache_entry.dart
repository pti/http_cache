import 'package:collection/collection.dart';
import 'package:http/http.dart';
import 'package:http_cache/http_cache.dart';
import 'package:http_cache/src/util/helpers.dart';
import 'package:http_cache/src/util/http_constants.dart';

class CacheKey {
  final Uri url;
  final Headers? varyHeaders;

  CacheKey(this.url, [this.varyHeaders]);

  bool hasMatchingVaryHeaders(Headers requestHeaders) {
    final varyHeaders = this.varyHeaders;

    if (varyHeaders == null) {
      return true;
    }

    return varyHeaders.entries.every((e) => e.value == requestHeaders[e.key]);
  }

  bool isMatching(Uri url, Headers headers) => this.url == url && hasMatchingVaryHeaders(headers);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CacheKey && runtimeType == other.runtimeType
              && url == other.url
              && const MapEquality<String, String>().equals(varyHeaders, other.varyHeaders);

  @override
  int get hashCode => url.hashCode ^ const MapEquality<String, String>().hash(varyHeaders);
}

class CacheEntryMeta {
  final CacheKey key;

  /// Date defined by the origin or if it was not available, then the local time when the response was received.
  final DateTime date;

  final CachingInfo info;
  final String? reasonPhrase;
  final Headers responseHeaders;

  CacheEntryMeta(this.key, this.date, this.info, this.reasonPhrase, this.responseHeaders);

  static CacheEntryMeta fromResponse(BaseRequest request, StreamedResponse response, CachingInfo info) {
    return CacheEntryMeta(
      CacheKey(request.url, request.readVaryHeaders(response)),
      response.headers.readDate(),
      info,
      response.reasonPhrase,
      response.headers,
    );
  }

  CacheEntryMeta withHeaders(Headers headers) {
    return CacheEntryMeta(
      key,
      headers.readDate(),
      info.withHeaders(headers),
      reasonPhrase,
      headers,
    );
  }
}

extension ExtraHeaders on Headers {
  DateTime? tryDate() => tryParseHttpDate(this[kHttpHeaderDate]);
  DateTime readDate() => tryDate() ?? DateTime.now();

  Duration? tryAge() {
    final ageSeconds = this[kHttpHeaderAge]?.tryParseInt();
    return ageSeconds == null ? null : Duration(seconds: ageSeconds);
  }
}

abstract class HttpCacheEntry extends CacheEntryMeta {
  HttpCacheEntry(super.key, super.date, super.info, super.reasonPhrase, super.responseHeaders);

  StreamedResponse toResponse(BaseRequest request, [StreamedResponse? response, CacheRequestContext? context]);
}

extension RequestExtras on BaseRequest {
  Headers? readVaryHeaders(BaseResponse response) {
    final varyKeys = response.headers[kHttpHeaderVary];

    if (varyKeys == kHttpVaryWildcard) {
      return Map.of(headers);

    } else if (varyKeys != null) {
      final entries = varyKeys
          .split(',')
          .map((e) {
            final name = e.trim();
            final value = headers[name];
            return value == null ? null : MapEntry(name, value);
          })
          .nonNulls;

      if (entries.isNotEmpty) {
        return Map.fromEntries(entries);
      }
    }

    return null;
  }
}
