
## Usage

To create a HTTP client with caching enabled:

```dart
// Remember to set the directory according to platform specific best practises.
final cache = FileCache(Directory('.http_cache'), maxSize: 10_000_000);

// Or alternatively use a cupertino_http for iOS/macOS, and cronet_http for Android
// (remember to configure them so that cache is disabled).
Client inner = Client();

final client = CachingClient(inner, cache);
```

Set the cache to "offline mode", e.g. when device connectivity status changes:
```dart
cache.mode = CacheMode.preferCached;
...
cache.mode = CacheMode.standard;
```
Or use `cachedOnError` to return the possible cached response when an (socket) error occurs - but depending on the
inner client timeout settings the response might not fail quickly.
