import 'dart:async';

typedef FutureBuilder<T> = Future<T> Function();

class Task<T> {
  final FutureBuilder<T> builder;
  final completer = Completer<T>();
  var _built = false;

  Task(this.builder);

  bool get isCompleted => completer.isCompleted;

  Future<T> run() async {
    try {
      if (_built) {
        return completer.future;
      } else {
        _built = true;
        final result = await builder();
        completer.complete(result);
        return result;
      }
    } catch (err) {
      completer.completeError(err);
      rethrow;
    }
  }
}
