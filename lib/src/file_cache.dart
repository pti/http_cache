import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart';
import 'package:http_cache/src/cache_control.dart';
import 'package:http_cache/src/caching_info.dart';
import 'package:http_cache/src/http_cache.dart';
import 'package:http_cache/src/http_cache_entry.dart';
import 'package:http_cache/src/util/buffered_writer.dart';
import 'package:http_cache/src/util/helpers.dart';
import 'package:http_cache/src/util/http_constants.dart';
import 'package:http_cache/src/util/locker.dart';
import 'package:http_cache/src/util/task.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

/// Cache that stores entries in separate files in the specified [directory].
///
/// Enables streaming cached responses from file system (compared to reading them fully into memory first) - this might
/// be useful for reducing memory consumption with larger responses. Especially in cases where the receiver is also
/// able to process the response in a streamed manner.
class FileCache extends HttpCache {

  /// Directory where to store the cache data.
  final Directory directory;

  /// Maximum cache size in bytes, defaults to 10MB. <=0 to disable.
  final int maxSize;

  /// Extra number of bytes to free when cache size has hit [maxSize].
  final int freeMargin;

  bool get _isCapped => maxSize > 0;

  List<EntryFilename>? _filenames;
  int? _currentSize;
  final _entries = <EntryFilename, FileCacheEntry>{};
  late final _initializer = Task(() => _initialize());
  Task<void>? _freer;

  Timer? _freeTimer;

  /// Used for synchronizing access to individual files, e.g. in case an entry needs to be evicted while still reading.
  final _sync = Locker<String>(const Duration(seconds: 5));

  FileCache(this.directory, {this.maxSize = 10_000_000, int? freeMargin}):
        freeMargin = freeMargin ?? (maxSize ~/ 10)
  {
    assert(this.freeMargin >= 0 && this.freeMargin <= maxSize);
  }

  @override
  void dispose() {
    _freeTimer?.cancel();
  }

  /// If [context] is defined, then [CacheRequestContext.onRequestCompleted] or [FileCacheRequestContext.onResponseConsumed]
  /// must be called.
  @override
  Future<HttpCacheEntry?> lookup(BaseRequest request, [covariant FileCacheRequestContext? context]) async {
    await _checkInitialize();

    final urlPart = request.url.toFilenamePart();
    final matches = _filenames!.where((fn) => fn.urlHash == urlPart).toList();

    if (matches.isEmpty) {
      return null;
    }

    FileCacheEntry? matchingEntry;

    for (final match in matches) {
      var entry = _entries[match];
      final file = entry?.file ?? _getAbsoluteFile(match);
      final key = _lockKey(file);
      Lock? lock;

      try {
        lock = await _sync.lock(key);

        if (entry == null) {
          entry = await FileCacheEntry._fromFile(file);

          if (entry != null) {
            _entries[match] = entry;

          } else {
            // Remove entry if reading it failed.
            await _evict(match, context);
          }
        }

        if (entry != null && entry.isMatch(request)) {
          // Wait for updating last accessed time in case it cannot be read (e.g. file was deleted since initialization).
          try {
            await entry.file.setLastAccessed(DateTime.now());
            matchingEntry = entry;

          } on PathNotFoundException catch (_) {
            _log('lookup: entry file not found - skip match');
            _entries.remove(match);
            _filenames?.remove(match);

          } catch (err, st) {
            _log('lookup: error setting last accessed', err, st);
          }

          break;
        }

      } finally {
        if (matchingEntry != null && context != null && lock != null) {
          // Keep locked until the request has been processed.
          await context.setLock(_sync, key, lock);
        } else {
          _sync.unlock(key);
        }
      }
    }

    return matchingEntry;
  }

  /// When called without [context], i.e. outside [send], then lock is released already at the end of this function.
  @override
  Future<HttpCacheEntry?> create(BaseRequest request, StreamedResponse response, CachingInfo info, [covariant FileCacheRequestContext? context]) async {
    await _checkInitialize();

    // If content length wasn't specified, then one just needs to read the response entirely to know the size.
    // And since the response has been consumed by then, it cannot be read again so the entry needs to be kept around
    // until streaming the response data from the file has completed.

    final meta = CacheEntryMeta.fromResponse(request, response, info);
    final filename = EntryFilename.fromKey(meta.key);
    final file = _getAbsoluteFile(filename);
    FileStat stat;
    int headerSize;
    final key = _lockKey(file);

    if (context != null && context.lock == null) {
      await context.setLock(_sync, key);
      // Released once the response stream is done.
    }

    return await _checkLock(context, key, () async {
      try {
        headerSize = await FileCacheEntry._toFile(meta, response.stream, file);
        stat = await file.stat();

        final result = FileCacheEntry(
          meta.key,
          meta.date,
          meta.info,
          meta.reasonPhrase,
          meta.responseHeaders,
          file,
          headerSize,
          filename,
          stat,
        );
        _addEntry(result, stat);

        return result;

      } catch (err, st) {
        _log('create: failed to write entry file $key', err, st);
        await file.delete().tryResult();
        rethrow;
      }
    });
  }

  /// The caller is expected to have written the file already.
  @override
  Future<void> add(covariant FileCacheEntry entry) async {
    await _checkInitialize();
    final stat = await entry.file.stat();
    _addEntry(entry, stat);
  }

  // TODO Future<void> addFile(File src, Uri url) async {

  void _addEntry(FileCacheEntry entry, FileStat stat) {
    // The file is added to cache even if maxSize would get exceeded. Space is freed after things have quietened down.
    _filenames?.add(entry.filename);
    _entries[entry.filename] = entry;
    _changeCurrentSize(stat.size);
  }

  @override
  Future<HttpCacheEntry?> update(covariant FileCacheEntry entry, Headers headers, [covariant FileCacheRequestContext? context]) async {
    await _checkInitialize();
    final existing = _entries[entry.filename];

    if (existing == null) {
      return null;
    }

    final key = _lockKey(entry.file);

    return await _checkLock(context, key, () async {
      final updated = await existing.updateWith(headers);
      _entries[entry.filename] = updated;
      return updated;
    });
  }

  @override
  Future<void> evict(CacheKey key, [covariant FileCacheRequestContext? context]) async {
    await _checkInitialize();
    final fn = EntryFilename.fromKey(key);
    await _evict(fn, context);
  }

  Future<void> _evict(EntryFilename fn, [FileCacheRequestContext? context]) async {
    final file = _getAbsoluteFile(fn);
    final key = _lockKey(file);

    await _checkLock(context, key, () async {
      _entries.remove(fn);
      final stat = await file.stat().tryResult();

      if (stat != null && stat.type == FileSystemEntityType.file) {
        await file.delete();
        _filenames?.removeWhere((f) => f.full == fn.full);
        _changeCurrentSize(-stat.size);
      }
    });
  }

  @override
  Future<void> clear() async {
    // Delete files individually in case the user has accidentally given a directory that is used for something
    // else too -- hoping that the file extension is sufficiently unique.
    await _checkInitialize();
    _cancelSpaceCheck();
    await _waitFreerDone();

    _freer = Task(() async {
      try {
        await Future.wait(_filenames?.map((f) => _evict(f).tryResult()) ?? []);
        await _initialize();
      } finally {
        _freer = null;
      }
    });
    await _freer?.run();
  }

  Future<void> _checkInitialize() async {
    if (_initializer.isCompleted) return;
    await _initializer.run();
  }

  Future<void> _initialize() async {

    if (await directory.exists() == false) {
      _log('Create cache directory ${directory.absolute}');
      await directory.create(recursive: true);
    }

    final result = await directory.listEntryFilenames();
    _filenames = result.map((r) => r.$2).toList();

    if (_isCapped) {
      final statted = await result.statAll();
      _currentSize = statted.map((s) => s.$3).nonNulls.map((s) => s.size).sum;
    }

    _log('Initialized, got ${_filenames!.length} entries, total size ${_currentSize!}B');
  }

  void _changeCurrentSize(int delta) {
    var current = _currentSize;
    if (current == null) return; // Not initialized yet (shouldn't even end up in here).

    current = _currentSize = current + delta;

    if (_isCapped && delta > 0 && current > maxSize) {
      _rescheduleSpaceCheck();
    } else {
      _cancelSpaceCheck();
    }
  }

  File _getAbsoluteFile(EntryFilename fn) => File(p.join(directory.path, fn.full));

  Future<void> _waitFreerDone() async {
    while (_freer != null) {
      await _freer?.run();
    }
  }

  void _cancelSpaceCheck() {
    _freeTimer?.cancel();
    _freeTimer = null;
  }

  void _rescheduleSpaceCheck() {
    _freeTimer?.cancel();
    _freeTimer = Timer(const Duration(seconds: 5), () {
      final current = _currentSize;

      if (current != null && current > 0 && current > maxSize) {
        _freeSpace(current - maxSize + freeMargin).ignore();
      }
    });
  }

  /// Free space by deleting least recently used files worth at least of [numBytes] bytes.
  Future<void> _freeSpace(int numBytes) async {
    await _waitFreerDone();
    _log('free space ${numBytes}B');
    _freer = Task(() async {
      try {
        final sw = Stopwatch()..start();
        final files = await directory.listEntryFilenames();
        final stats = await files.statAll();
        var totalEvictionSize = 0;
        final evictions = stats
            .where((s) => s.$3 != null)
            .map((s) => (s.$1, s.$2, s.$3!))
            .sorted((a, b) => a.$3.accessed.millisecondsSinceEpoch - b.$3.accessed.millisecondsSinceEpoch)
            .takeWhile((s) {
              final take = totalEvictionSize < numBytes;
              totalEvictionSize += s.$3.size;
              return take;
            })
            .map((s) => _evict(s.$2));
        await Future.wait(evictions);
        _freer = null;
        _log('Cleared ${totalEvictionSize}B in ${sw.elapsedMicroseconds}µs, now ${_currentSize}B total');

      } catch (err, st) {
        _log('Error freeing up space - resort to clearing', err, st);
        _freer = null;
        await clear();
      }
    });
    await _freer?.run();
  }

  String _lockKey(File file) => file.path;

  Future<T> _checkLock<T>(FileCacheRequestContext? context, String key, FutureBuilder<T> action) async {
    final lock = context?.lock == null;

    try {
      if (lock) await _sync.lock(key);
      return await action.call();

    } finally {
      if (lock) _sync.unlock(key);
    }
  }

  @override
  FileCacheRequestContext createRequestContext(BaseRequest request) => FileCacheRequestContext(request);
}

void _log(String msg, [Object? err, StackTrace? stackTrace]) => HttpCache.logger?.log(msg, err, stackTrace);

class EntryFilename {

  static const _extension = '.hfce';
  static const _varySeparator = '_';

  final String full;
  final String urlHash;
  final String? varyHash;

  EntryFilename(this.full, this.urlHash, this.varyHash);

  static EntryFilename? parse(String filename) {
    if (!filename.endsWith(_extension)) return null;

    final extensionless = filename.substring(0, filename.length - _extension.length);
    final separator = extensionless.indexOf(_varySeparator);

    if (separator == -1) {
      return EntryFilename(filename, extensionless, null);
    } else if (separator == 0 || separator == extensionless.length - 1) {
      return null;
    } else {
      return EntryFilename(filename, extensionless.substring(0, separator), extensionless.substring(separator + 1));
    }
  }

  static EntryFilename fromKey(CacheKey key) {
    final urlHash = key.url.toFilenamePart();
    String? varyHash;
    String full;

    if (key.varyHeaders != null) {
      varyHash = _filenameHash(key.varyHeaders!
          .entries
          .sortedBy((e) => e.key)
          .map((e) => '${e.key}=${e.value}')
          .join('\n'));
      full = '$urlHash$_varySeparator$varyHash$_extension';
    } else {
      full = '$urlHash$_extension';
    }

    return EntryFilename(full, urlHash, varyHash);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is EntryFilename && runtimeType == other.runtimeType && full == other.full &&
              urlHash == other.urlHash && varyHash == other.varyHash;

  @override
  int get hashCode => full.hashCode;
}

class FileCacheEntry extends HttpCacheEntry {
  final File file;
  final int metaLength;
  final EntryFilename filename;
  final FileStat stat;

  FileCacheEntry(super.key, super.date, super.info, super.reasonPhrase, super.responseHeaders,
      this.file, this.metaLength, this.filename, this.stat);

  static Future<FileCacheEntry?> _fromFile(File file) async {

    try {
      final stat = await file.stat();

      if (stat.type == FileSystemEntityType.notFound) {
        return null;
      }

      final res = await _EntryFileHeader.read(file);

      if (res == null) {
        return null;
      }

      final header = res.$1;
      final metaLength = res.$2;
      final meta = header.meta;
      final fn = EntryFilename.fromKey(meta.key);
      return FileCacheEntry(meta.key, meta.date, meta.info, meta.reasonPhrase, meta.responseHeaders, file, metaLength, fn, stat);

    } catch (err, st) {
      _log('Failed to read entry $file', err, st);
      return null;
    }
  }

  static Future<int> _toFile(CacheEntryMeta meta, Stream<List<int>> contentStream, File file) async {
    return __toFile(meta.toBytes(), contentStream, file);
  }

  static Future<int> __toFile(Uint8List metaBytes, Stream<List<int>> contentStream, File file) {
    return file.parentGuardedWrite(FileMode.writeOnly, (output) async {
      final buf = BufferedWriter(output);
      final metaLength = await _EntryFileHeader._write(buf, _EntryFileHeader._supportedVersion, metaBytes);

      await for (final chunk in contentStream) {
        await buf.write(chunk);
      }

      await buf.flush();
      return metaLength;
    });
  }

  static Future<void> _overwriteHeaders(Uint8List metaBytes, File file) async {
    return file.parentGuardedWrite(FileMode.writeOnlyAppend, (raf) async {
      await raf.setPosition(_EntryFileHeader._fixedSize);
      await raf.writeFrom(metaBytes);
      await raf.flush();
    });
  }

  @override
  StreamedResponse toResponse(BaseRequest request, [StreamedResponse? response, covariant FileCacheRequestContext? context]) {
    final contentOffset = _EntryFileHeader._fixedSize + metaLength;

    if (contentOffset > stat.size) {
      throw ArgumentError('Invalid contentOffset (offset=$contentOffset, file=${stat.size}, meta=$metaLength)');
    }

    var stream = file.openRead(contentOffset);
    final onComplete = context?.onResponseConsumed;
    context?.waitingResponse = true;

    if (onComplete != null) {
      stream = stream
          .doOnCancel(() => onComplete(null))
          .doOnDone(() => onComplete(null))
          .doOnError((err, _) => onComplete(err));
    }

    return StreamedResponse(
      stream,
      info.statusCode,
      request: request,
      contentLength: stat.size - contentOffset,
      persistentConnection: response?.persistentConnection ?? false,
      reasonPhrase: reasonPhrase,
      isRedirect: response?.isRedirect ?? false,
      headers: responseHeaders,
    );
  }

  bool isMatch(BaseRequest request) {
    return key.url == request.url
        && (key.varyHeaders?.entries.every((e) => request.headers[e.key] == e.value) ?? true);
  }

  Future<FileCacheEntry> updateWith(Headers headers) async {
    final newMeta = withHeaders(headers);
    final newMetaBytes = newMeta.toBytes();
    final newMetaLength = newMetaBytes.lengthInBytes;

    // If the part before the content remains the same, just overwrite it to the file.
    // Otherwise create a new file. Perhaps this could be improved by writing the "meta" to a separate file or perhaps
    // a database, or reserving some extra room.
    if (newMetaLength == metaLength) {
      _log('update file entry, ${file.path}');
      await FileCacheEntry._overwriteHeaders(newMetaBytes, file);

    } else {
      _log('meta length changed ($metaLength → $newMetaLength) - create a new entry file, ${file.path}');
      final tmp = File('${file.path}.tmp');
      final offset = _EntryFileHeader._fixedSize + metaLength;
      await FileCacheEntry.__toFile(newMetaBytes, file.openRead(offset), tmp);
      await tmp.rename(file.path);
    }

    return FileCacheEntry(key, headers.readDate(), info.withHeaders(headers), reasonPhrase, headers, file, newMetaLength, filename, stat);
  }
}

extension JsonCacheKey on CacheKey {
  static const _keyUrl = 'u';
  static const _keyVary = 'v';

  static CacheKey fromJson(Map<String, dynamic> json) {
    final url = Uri.parse(json[_keyUrl] as String);
    final vary = json.tryMap<String>(_keyVary);
    return CacheKey(url, vary);
  }

  Map<String, dynamic> toJson() => {
    _keyUrl: url.toString(),
    _keyVary: ?varyHeaders
  };
}

extension JsonCachingInfo on CachingInfo {
  static const _keyStatusCode = 's';
  static const _keyCacheControl = 'c';
  static const _keyVaryHeaders = 'v';
  static const _keyEtag = 't';
  static const _keyExpires = 'x';
  static const _keyLastModified = 'l';

  static CachingInfo fromJson(Map<String, dynamic> json) {
    return CachingInfo(
      json[_keyStatusCode] as int,
      CacheControl(json.readMap<Object>(_keyCacheControl)),
      json[_keyVaryHeaders] as String?,
      json[_keyEtag] as String?,
      json.tryTimestamp(_keyExpires),
      json.tryTimestamp(_keyLastModified),
    );
  }

  Map<String, dynamic> toJson() => {
    _keyStatusCode: statusCode,
    _keyCacheControl: control?.directives,
    _keyVaryHeaders: ?vary,
    _keyEtag: ?etag,
    _keyExpires: ?expires?.toTimestamp(),
    _keyLastModified: ?lastModified?.toTimestamp(),
  };
}

extension JsonCacheEntryMeta on CacheEntryMeta {
  static const _keyCacheKey = 'k';
  static const _keyDate = 'd';
  static const _keyReason = 'r';
  static const _keyHeaders = 'h';
  static const _keyInfo = 'i';

  static CacheEntryMeta fromJson(Map<String, dynamic> json) {
    final key = JsonCacheKey.fromJson(json.readMap(_keyCacheKey));
    final date = json.tryTimestamp(_keyDate)!;
    final reason = json[_keyReason] as String?;
    final headers = json.readMap<String>(_keyHeaders);
    final info = JsonCachingInfo.fromJson(json.readMap<dynamic>(_keyInfo));
    return CacheEntryMeta(key, date, info, reason, headers);
  }

  Map<String, dynamic> toJson() => {
    _keyCacheKey: key.toJson(),
    _keyDate: date.toTimestamp(),
    _keyReason: ?reasonPhrase,
    _keyHeaders: responseHeaders,
    _keyInfo: info.toJson(),
  };
}

extension on Uri {
  String toFilenamePart() => _filenameHash(toString());
}

String _filenameHash(String source) => md5.convert(utf8.encode(source)).toString();

extension on Map<String, dynamic> {
  Map<String, T> castValues<T>() => map((k, v) => MapEntry(k, v as T));

  DateTime? tryTimestamp(String key) => (this[key] as int?)?.toDateTime();

  Map<String, T> readMap<T>(String key) => (this[key] as Map<String, dynamic>).castValues<T>();

  Map<String, T>? tryMap<T>(String key) => (this[key] as Map<String, dynamic>?)?.castValues<T>();
}

extension on int {
  DateTime toDateTime() => DateTime.fromMillisecondsSinceEpoch(this);
}

extension on DateTime {
  int toTimestamp() => millisecondsSinceEpoch;
}

extension on Directory {
  Future<List<(FileSystemEntity, EntryFilename)>> listEntryFilenames() {
    return list(followLinks: false)
        .where((fse) => fse is File)
        .map((f) => (f, EntryFilename.parse(p.basename(f.path))))
        .where((r) => r.$2 != null)
        .map((r) => (r.$1, r.$2!))
        .toList();
  }
}

extension on List<(FileSystemEntity, EntryFilename)> {
  Future<List<(FileSystemEntity, EntryFilename, FileStat?)>> statAll() {
    return Future.wait(map((r) async {
      final stat = await r.$1.stat().tryResult();
      return (r.$1, r.$2, stat);
    }));
  }
}

class _EntryFileHeader {
  static const _fixedSize = 8;
  static const _supportedVersion = 1;

  final int version;
  final CacheEntryMeta meta;

  _EntryFileHeader(this.meta, [this.version = _supportedVersion]);

  static Future<(_EntryFileHeader, int)?> read(File file) async {
    RandomAccessFile? raf;

    try {
      raf = await file.open();
      final input = ByteData.sublistView(await raf.read(_fixedSize));
      final version = input.getUint32(0);

      if (version != _supportedVersion) {
        return null;
      }

      final metaLength = input.getUint32(4);
      final metaBytes = await raf.read(metaLength);
      final headerJson = jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;
      final meta = JsonCacheEntryMeta.fromJson(headerJson);
      return (_EntryFileHeader(meta, version), metaLength);

    } finally {
      await raf?.close();
    }
  }

  static Future<int> _write(BufferedWriter out, int version, Uint8List metaBytes) async {
    final metaLength = metaBytes.lengthInBytes;
    final fixedData = ByteData(_fixedSize)
      ..setUint32(0, version)
      ..setUint32(4, metaLength);
    await out.write(fixedData.buffer.asUint8List());
    await out.write(metaBytes);
    return metaLength;
  }
}

extension on CacheEntryMeta {
  Uint8List toBytes() => utf8.encode(jsonEncode(toJson()));
}

/// Context is used for keeping access to response specific file locked for the duration of the whole request.
/// This means that the lock is also held during remote requests that may take a while. One could release the lock
/// for the duration of the remote request, but then again even if another request to the same resource is made while
/// processing the first one, it would still end up doing the same remote validation request, i.e. duplicating the
/// request. By keeping the lock for the whole process, the second request is able to utilize the cache response
/// (if the response was cacheable). Of course if the second request uses [CacheMode.preferCached] it would need to
/// wait longer than if lock wouldn't be kept the whole time (assuming that the remote request takes the most time).
class FileCacheRequestContext extends CacheRequestContext {
  Locker<String>? locker;
  String? lockKey;
  Lock? lock;
  var waitingResponse = false;

  FileCacheRequestContext(super.request);

  Future<void> setLock(Locker<String> locker, String lockKey, [Lock? lock]) async {
    this.locker = locker;
    this.lockKey = lockKey;
    this.lock = lock ?? await locker.lock(lockKey);
  }

  @override
  void onRequestCompleted(Object? err) {
    if (!waitingResponse) {
      _unlock();
    }
  }

  void onResponseConsumed(Object? err) {
    _unlock();
  }

  void _unlock() {
    if (lockKey != null && locker != null) {
      locker?.unlock(lockKey!);
      lock = null;
      locker = null;
      lock = null;
    }
  }
}

extension on File {
  Future<bool> checkParentExists() async {
    if (await parent.exists()) {
      return false;

    } else {
      await parent.create(recursive: true);
      return true;
    }
  }

  Future<T> exec<T>(FileMode mode, Future<T> Function(RandomAccessFile output) action) async {
    RandomAccessFile? output;

    try {
      output = await open(mode: mode);
      return await action(output);

    } finally {
      await output?.close().tryResult();
    }
  }

  Future<T> parentGuardedWrite<T>(FileMode mode, Future<T> Function(RandomAccessFile output) action) async {
    try {
      return await exec(mode, action);

    } on PathNotFoundException catch (_) {
      if (await checkParentExists()) {
        _log('file parent was missing, created it - retry write');
        return await exec(mode, action);
      } else {
        rethrow;
      }
    }
  }
}
