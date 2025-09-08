import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class BufferedWriter {

  final RandomAccessFile _output;
  Uint8List _buf;
  var _pos = 0;

  BufferedWriter(this._output, {int bufferSize = 16 * 1024}):
        _buf = Uint8List(bufferSize);

  Future<void> close() {
    return _output.close();
  }

  Future<void> write(List<int> data) async {
    var remaining = data.length;
    var offset = 0;

    while (remaining > 0) {
      final capacity = _buf.lengthInBytes - _pos;
      final size = min(remaining, capacity);
      _buf.setRange(_pos, _pos + size, data, offset);

      remaining -= size;
      offset += size;
      _pos += size;

      if (_pos == _buf.lengthInBytes) {
        await _writeBuffer();

        if (remaining > 0) {
          // Open a new buffer in case the buffer would get modified during add().
          _buf = Uint8List(_buf.lengthInBytes);
        }
      }
    }
  }

  Future<void> _writeBuffer() async{
    if (_pos == 0) return;
    await _output.writeFrom(_buf, 0, _pos);
    _pos = 0;
  }

  Future<void> flush() async {
    await _writeBuffer();
    await _output.flush();
  }
}
