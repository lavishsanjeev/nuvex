import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/pointycastle.dart';

/// Cryptographic engine for Nuvex Locked Folder media encryption and decryption.
///
/// Security Specifications:
/// - Cipher: AES-256-GCM (Galois/Counter Mode with 128-bit authentication tag)
/// - Nonce / IV: 96-bit (12 bytes) cryptographically random nonce generated per file
/// - Authenticated encryption: guarantees confidentiality, tamper resistance, and data integrity
/// - Verification: writes temporary file, verifies decryption & authentication tag before finalizing
/// - Header: [Magic 4B: 'NVXL'] [Version 1B: 0x01] [IV 12B] [Ciphertext + 16B Auth Tag]
class LockedMediaCryptor {
  static const List<int> _magicHeader = [0x4E, 0x56, 0x58, 0x4C]; // "NVXL"
  static const int _version = 1;
  static const int _nonceLength = 12; // 96 bits standard for GCM
  static const int _tagLengthBits = 128; // 16 bytes auth tag

  /// Encrypts in-memory [plaintext] into protected container bytes using [masterKey].
  static Uint8List encryptBytes({
    required Uint8List plaintext,
    required Uint8List masterKey,
  }) {
    if (masterKey.length != 32) {
      throw ArgumentError('Master key must be 256 bits (32 bytes)');
    }

    final nonce = _generateRandomBytes(_nonceLength);
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(masterKey),
      _tagLengthBits,
      nonce,
      Uint8List(0),
    );
    cipher.init(true, params);

    final ciphertext = cipher.process(plaintext);

    final output = BytesBuilder(copy: false)
      ..add(_magicHeader)
      ..addByte(_version)
      ..add(nonce)
      ..add(ciphertext);

    return output.takeBytes();
  }

  /// Encrypts [sourceFile] into [destinationFile] using [masterKey].
  ///
  /// Automatically verifies that the resulting ciphertext can be decrypted
  /// before returning successfully. If encryption or verification fails,
  /// the temporary file is deleted and an exception is thrown.
  static Future<void> encryptFile({
    required File sourceFile,
    required File destinationFile,
    required Uint8List masterKey,
  }) async {
    if (masterKey.length != 32) {
      throw ArgumentError('Master key must be 256 bits (32 bytes)');
    }
    if (!await sourceFile.exists()) {
      throw FileSystemException('Source file does not exist', sourceFile.path);
    }

    final plaintext = await sourceFile.readAsBytes();
    final containerBytes = encryptBytes(
      plaintext: plaintext,
      masterKey: masterKey,
    );

    // 4. Write to temporary file first
    final tempPath = '${destinationFile.path}.tmp_${DateTime.now().microsecondsSinceEpoch}';
    final tempFile = File(tempPath);
    if (!await tempFile.parent.exists()) {
      await tempFile.parent.create(recursive: true);
    }
    await tempFile.writeAsBytes(containerBytes, flush: true);

    // 5. Verification step: verify decryptability before replacing destination
    try {
      final verifyBytes = decryptBytes(
        encryptedBytes: containerBytes,
        masterKey: masterKey,
      );
      if (verifyBytes.length != plaintext.length) {
        throw StateError('Encryption verification failed: length mismatch');
      }

      // Safe atomic commit
      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }
      await tempFile.rename(destinationFile.path);
    } catch (e) {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      throw StateError('Encryption verification failed: $e');
    }
  }

  /// Decrypts [encryptedFile] into [destinationFile] using [masterKey].
  static Future<void> decryptFile({
    required File encryptedFile,
    required File destinationFile,
    required Uint8List masterKey,
  }) async {
    if (!await encryptedFile.exists()) {
      throw FileSystemException('Encrypted file does not exist', encryptedFile.path);
    }

    final encryptedBytes = await encryptedFile.readAsBytes();
    final plaintext = decryptBytes(
      encryptedBytes: encryptedBytes,
      masterKey: masterKey,
    );

    final tempPath = '${destinationFile.path}.tmp_${DateTime.now().microsecondsSinceEpoch}';
    final tempFile = File(tempPath);
    if (!await tempFile.parent.exists()) {
      await tempFile.parent.create(recursive: true);
    }
    await tempFile.writeAsBytes(plaintext, flush: true);

    if (await destinationFile.exists()) {
      await destinationFile.delete();
    }
    await tempFile.rename(destinationFile.path);
  }

  /// Decrypts in-memory [encryptedBytes] directly into raw plaintext bytes.
  /// Used for on-demand private thumbnail and media display without writing plaintext to disk.
  static Uint8List decryptBytes({
    required Uint8List encryptedBytes,
    required Uint8List masterKey,
  }) {
    if (masterKey.length != 32) {
      throw ArgumentError('Master key must be 256 bits (32 bytes)');
    }

    // Minimum length = 4B (magic) + 1B (version) + 12B (nonce) + 16B (min tag) = 33 bytes
    if (encryptedBytes.length < 33) {
      throw const FormatException('Invalid locked media container format: file too short');
    }

    // Check magic
    for (int i = 0; i < 4; i++) {
      if (encryptedBytes[i] != _magicHeader[i]) {
        throw const FormatException('Invalid locked media format: header signature mismatch');
      }
    }

    final version = encryptedBytes[4];
    if (version != _version) {
      throw FormatException('Unsupported locked media container version: $version');
    }

    final nonce = encryptedBytes.sublist(5, 5 + _nonceLength);
    final ciphertextWithTag = encryptedBytes.sublist(5 + _nonceLength);

    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(masterKey),
      _tagLengthBits,
      nonce,
      Uint8List(0),
    );
    cipher.init(false, params);

    try {
      return cipher.process(ciphertextWithTag);
    } catch (e) {
      throw StateError('Decryption failed: invalid key or tampered ciphertext ($e)');
    }
  }

  static Uint8List _generateRandomBytes(int length) {
    final rnd = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return bytes;
  }
}
