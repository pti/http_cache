import 'dart:async';

import 'package:http/http.dart';
import 'package:http_cache/src/util/locker.dart';

/// Used for eliminating simultaneous identical requests or other operations that should
/// result in the same result.
class RequestCoupler<K> {

  // TODO ditch completer if it is old enough (configurable param)

  final _requests = <K, Completer<dynamic>>{};
  final _locker = Locker<K>();

  void remove(K key) {
    _requests.remove(key);
  }

  Future<R> request<R>(K key, Future<R> Function() requester) async {

    if (R == StreamedResponse) {
      // The stream in StreamedResponses is a single-subscription one, so it cannot be reused.
      // One could multiplex the stream, but that likely means storing the response in memory and
      // requires unnecessary work if there are no other similar requests being made.
      // Instead wait for previous instance of the request to complete before making a new one.
      // This way if a cache is used and the response is cacheable, then at least any later requests
      // can utilize the cache (more likely).
      // It is also possible that the same resource is requested in a different manner that doesn't
      // entail streaming → mark locks separately.
      return _locker.run(key, requester);

    } else {
      Completer<R>? completer = _requests[key] as Completer<R>?;

      if (completer != null) {
        return completer.future;
      }

      completer = Completer<R>();
      _requests[key] = completer;

      try {
        final resp = await requester();
        completer.complete(resp);
        return resp;
      } catch (err) {
        completer.completeError(err);
        rethrow;
      } finally {
        if (identical(_requests[key], completer)) {
          _requests.remove(key);
        }
      }
    }
  }
}
