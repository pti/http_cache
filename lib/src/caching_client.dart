import 'package:http/http.dart';
import 'package:http_cache/src/http_cache.dart';

class CachingClient extends BaseClient {
  final Client inner;
  final HttpCache cache;

  CachingClient(this.inner, this.cache);

  @override
  void close() {
    inner.close();
  }

  @override
  Future<StreamedResponse> send(BaseRequest request) {
    return cache.send(request, inner);
  }

  Future<Response> sendUnstreamed(BaseRequest request) async {
    final response = await send(request);
    return await Response.fromStream(response);
  }
}
