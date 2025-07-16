
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
