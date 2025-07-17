import 'package:http_parser/http_parser.dart';

extension ExtraString on String {
  int? tryParseInt() => int.tryParse(this);
}

extension ExtraFuture<T> on Future<T> {
  Future<T?> tryResult() async {
    try {
      return await this;
    } catch (err) {
      return null;
    }
  }
}

DateTime? tryParseHttpDate(String? value) {

  if (value == null) {
    return null;
  }

  try {
    return parseHttpDate(value);
  } on FormatException catch (_) {
    return null;
  }
}
