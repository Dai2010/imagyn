import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

final _crcTable = List<int>.generate(256, (n) {
  var value = n;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// Reads the stored archive back the way a package reader would: through the
/// central directory, checking each entry's CRC instead of trusting the bytes.
Map<String, Uint8List> unzipPptx(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  expect(eocd, isNonNegative, reason: 'end of central directory');
  final count = data.getUint16(eocd + 10, Endian.little);
  var offset = data.getUint32(eocd + 16, Endian.little);
  final files = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    expect(data.getUint32(offset, Endian.little), 0x02014b50);
    expect(data.getUint16(offset + 10, Endian.little), 0, reason: 'stored');
    final crc = data.getUint32(offset + 16, Endian.little);
    final size = data.getUint32(offset + 20, Endian.little);
    final nameLength = data.getUint16(offset + 28, Endian.little);
    final extraLength = data.getUint16(offset + 30, Endian.little);
    final commentLength = data.getUint16(offset + 32, Endian.little);
    final local = data.getUint32(offset + 42, Endian.little);
    final name = utf8.decode(
      Uint8List.sublistView(bytes, offset + 46, offset + 46 + nameLength),
    );
    expect(data.getUint32(local, Endian.little), 0x04034b50);
    final localName = data.getUint16(local + 26, Endian.little);
    final localExtra = data.getUint16(local + 28, Endian.little);
    final start = local + 30 + localName + localExtra;
    final content = Uint8List.sublistView(bytes, start, start + size);
    expect(_crc32(content), crc, reason: name);
    files[name] = content;
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return files;
}
