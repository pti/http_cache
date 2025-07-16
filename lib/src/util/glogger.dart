
typedef LogPrinter = void Function(String msg);

class GLogger {
  static final sw = Stopwatch()..start();
  final LogPrinter printer;

  GLogger({this.printer = print});

  void log(String msg) {
    printer('${sw.elapsedMicroseconds.toString().padLeft(10)}µs - $msg');
    sw.reset();
  }
}
