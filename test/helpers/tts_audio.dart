import 'dart:typed_data';

/// Valid, silent PCM WAV. Never contains a user's text or credentials.
Uint8List silentTtsWav({int milliseconds = 250}) {
  final samples = milliseconds * 8; // 8 kHz, mono, signed 16-bit.
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void ascii(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
  ascii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}
