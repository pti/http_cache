import 'package:http_cache/http_cache.dart';
import 'package:http_cache/src/util/helpers.dart';
import 'package:http_cache/src/util/http_constants.dart';
import 'package:test/test.dart';

void main() {
  group('HttpDate', () {
    test('tryParse', () {
      expect(tryParseHttpDate('Fri, 09 Feb 2018 19:20:21 GMT'), DateTime.utc(2018, DateTime.february, 9, 19, 20, 21));
      expect(tryParseHttpDate('Friday, 09 Feb 2018 19:20:21 GMT'), null);
      expect(tryParseHttpDate('Fri, 09 Feb 2018 9:20:21 GMT'), null);
      expect(tryParseHttpDate('Fri, 09 Feb 2018 AB:20:21 GMT'), null);
    });
  });
  group('CacheControl', () {
    test('fromResponse1', () {
      final c = CacheControl.fromResponse({kHttpHeaderCacheControl: 'max-age=1234'});
      expect(c, isNotNull);
      expect(c?.maxAge, 1234);
    });
    test('fromResponse2', () {
      final c = CacheControl.fromResponse({kHttpHeaderCacheControl: 'max-age=0, no-cache'});
      expect(c, isNotNull);
      expect(c?.maxAge, 0);
      expect(c?.noCache, true);
    });
    test('fromResponse3', () {
      final c = CacheControl.fromResponse({kHttpHeaderCacheControl: 'public, max-age=3600'});
      expect(c, isNotNull);
      expect(c?.directives['public'], true);
      expect(c?.maxAge, 3600);
    });
  });
}
