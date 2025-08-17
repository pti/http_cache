
typedef LogPrinter = void Function(String msg, [Object? err, StackTrace? stackTrace]);

class GLogger {
  static final sw = Stopwatch()..start();
  final LogPrinter printer;

  GLogger(this.printer);

  void log(String msg, [Object? err, StackTrace? stackTrace]) {
    printer('${sw.elapsedMicroseconds.toString().padLeft(10)}µs - $msg', err, stackTrace);
    sw.reset();
  }
}
