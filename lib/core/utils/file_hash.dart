import 'dart:io';

import 'package:crypto/crypto.dart';

/// Calculates the SHA-256 hash strictly from the ORIGINAL raw file bytes.
///
/// Streams chunks sequentially without loading massive files completely into memory.
/// Never hashes thumbnails or scaled images — guarantees genuine file integrity check.
Future<String> calculateFileSha256(File file) async {
  if (!await file.exists()) {
    throw FileSystemException('Cannot hash non-existent file', file.path);
  }
  final stream = file.openRead();
  final digest = await sha256.bind(stream).first;
  return digest.toString();
}
