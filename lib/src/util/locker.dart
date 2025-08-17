import 'dart:async';

import 'package:http_cache/http_cache.dart';
import 'package:http_cache/src/util/task.dart';

typedef Lock = Completer<void>;

class Locker<K> {
  final _completersByKey = <K, Lock>{};
  final Duration? defaultTimeout;

  Locker([this.defaultTimeout]);

  Future<R> run<R>(K key, FutureBuilder<R> action) async {
    try {
      await lock(key);
      return await action.call();
    } finally {
      unlock(key);
    }
  }

  Future<Lock> lock(K key, [Duration? timeout]) async {
    var completer = _completersByKey[key];
    timeout ??= defaultTimeout;

    while (completer != null) {
      try {
        if (timeout != null) {
          await completer.future.timeout(timeout);
        } else {
          await completer.future;
        }
      } on TimeoutException catch (_) {
        HttpCache.logger?.log('lock: wait timed out for $key');
        break;
      }
      completer = _completersByKey[key];
    }

    completer = Completer();
    _completersByKey[key] = completer;
    return completer;
  }

  void unlock(K key) {
    final completer = _completersByKey.remove(key);
    completer?.complete();
  }

  int get size => _completersByKey.length;
}
