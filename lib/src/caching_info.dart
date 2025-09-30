import 'dart:math';

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
    var control = CacheControl.fromHeaders(headers);
    DateTime? expires;

    if (request is CacheableRequest) {
      final controlOverride = request.control;

      if (controlOverride != null) {
        control = control?.override(controlOverride) ?? controlOverride;
      }

      expires = request.expires;
    }

    control ??= defaultControl;

    final vary = headers[kHttpHeaderVary];
    final etag = headers[kHttpHeaderETag];
    expires ??= _readExpires(headers, control);
    final lastModified = tryParseHttpDate(headers[kHttpHeaderLastModifiedHeader]);
    return CachingInfo(statusCode, control, vary, etag, expires, lastModified);
  }

  CachingInfo withHeaders(Headers headers) {
    final control = CacheControl.fromHeaders(headers) ?? this.control;
    final vary = headers[kHttpHeaderVary];
    final etag = headers[kHttpHeaderETag];
    final expires = _readExpires(headers, control);
    final lastModified = tryParseHttpDate(headers[kHttpHeaderLastModifiedHeader]);
    return CachingInfo(statusCode, control, vary, etag, expires, lastModified);
  }

  bool isCacheable() {
    // https://developer.mozilla.org/en-US/docs/Glossary/cacheable
    const cacheableStatuses = {200, 203, 204, 206, 300, 301, 404, 405, 410, 414, 501};

    if (!cacheableStatuses.contains(statusCode)) {
      return false;
    }

    // "Implies that the response is uncacheable." - https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Vary
    if (vary == kHttpVaryWildcard) {
      return false;
    }

    return control?.noStore != true;
  }

  bool hasExpired([DateTime? ref]) {
    return expires == null || (ref ?? DateTime.now()).isAfter(expires!);
  }

  bool shouldValidate([DateTime? ref]) {
    return control?.noCache == true || hasExpired(ref);
  }
}

DateTime? _readExpires(Headers headers, CacheControl? control) {
  final now = DateTime.now();
  final minFresh = control?.minFresh;
  final date = headers.tryDate();
  final age = headers.tryAge() ?? Duration.zero;
  var maxAge = control?.maxAge;
  Duration? currentAge;
  DateTime? expires;

  if (date != null) {
    // https://httpwg.org/specs/rfc9111.html#age.calculations
    // TODO provide response&request times
    final responseTime = now;
    final requestTime = now;
    final apparentAge = Duration(milliseconds: max(0, responseTime.difference(date).inMilliseconds));
    final responseDelay = responseTime.difference(requestTime);
    final correctedAgeValue = age + responseDelay;
    final correctedInitialAge = Duration(milliseconds: max(apparentAge.inMilliseconds, correctedAgeValue.inMilliseconds));
    final residentTime = now.difference(responseTime);
    currentAge = correctedInitialAge + residentTime;
  }

  // TODO heuristic freshness - https://httpwg.org/specs/rfc9111.html#heuristic.freshness
  if (maxAge != null) {
    // https://httpwg.org/specs/rfc9111.html#expiration.model
    // Date: "The "Date" header field represents the date and time at which the message was originated" - https://httpwg.org/specs/rfc9110.html#field.date
    // Age: "The "Age" response header field conveys the sender's estimate of the time since the response was generated or successfully validated at the origin server" - https://httpwg.org/specs/rfc9111.html#field.age
    // In some cases date+age values do not make any sense: date is ~ now, but age is several hours + max-age is
    // seconds/minutes, i.e. the response has already been stale for several hours.
    // Is there some logic that should be accounted for here or always handled as already stale?
    final remaining = maxAge - (currentAge ?? Duration.zero);
    expires = remaining > Duration.zero ? now.add(remaining) : null;

  } else {
    expires = tryParseHttpDate(headers[kHttpHeaderExpires]);
  }

  if (minFresh != null) {
    final minExpires = now.add(minFresh);

    if (expires == null || minExpires.isAfter(expires)) {
      expires = minExpires;
    }
  }

  return expires;
}
