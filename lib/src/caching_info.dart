import 'package:http/http.dart';
import 'package:http_cache/http_cache.dart';
import 'package:http_cache/src/util/http_constants.dart';

import 'util/helpers.dart';

class CachingInfo {
  final int statusCode;
  final CacheControl? control;
  final String? vary;
  final String? etag;

  /// Expires timestamp resolved when response was received.
  final DateTime? expires;

  final DateTime? lastModified;

  CachingInfo(this.statusCode, this.control, this.vary, this.etag, this.expires, this.lastModified);

  factory CachingInfo.fromResponse(BaseRequest request, int statusCode, Headers headers, CacheControl? defaultControl) {
    var control = CacheControl.fromResponse(headers);

    if (request is CacheableRequest && request.control != null) {
      control = request.control;
    }

    control ??= defaultControl;

    final vary = headers[kHttpHeaderVary];
    final etag = headers[kHttpHeaderETag];
    final expires = _readExpires(headers, control);
    final lastModified = tryParseHttpDate(headers[kHttpHeaderLastModifiedHeader]);
    return CachingInfo(statusCode, control, vary, etag, expires, lastModified);
  }

  bool isCacheable() {
    // For now only handle a subset of responses cacheable - https://developer.mozilla.org/en-US/docs/Glossary/cacheable
    if (statusCode != kHttpStatusOk) {
      return false;
    }

    // "Implies that the response is uncacheable." - https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Vary
    if (vary == kHttpVaryWildcard) {
      return false;
    }

    return control?.noStore != true;
  }

  bool hasExpired([DateTime? ref]) {
    return expires != null && (ref ?? DateTime.now()).isAfter(expires!);
  }

  bool shouldValidate([DateTime? ref]) {
    return control?.noCache == true || hasExpired(ref);
  }
}

DateTime? _readExpires(Headers headers, CacheControl? control) {
  final age = headers[kHttpHeaderAge]?.tryParseInt();
  final maxAge = control?.maxAge;

  if (maxAge != null) {
    return DateTime.now().add(Duration(seconds: maxAge - (age ?? 0)));
  } else {
    return tryParseHttpDate(headers[kHttpHeaderExpires]);
  }
}
