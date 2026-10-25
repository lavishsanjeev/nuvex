import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/database/nuvex_database.dart';
import 'package:nuvex/core/database/remote_file.dart';
import 'package:nuvex/core/storage/secure_storage.dart';
import 'package:nuvex/features/home/repositories/media_repository.dart';
import 'package:nuvex/features/locked_folder/controllers/locked_folder_controller.dart';
import 'package:nuvex/features/locked_folder/repositories/locked_folder_repository.dart';
import 'package:nuvex/features/locked_folder/services/locked_folder_auth_service.dart';
import 'package:nuvex/features/locked_folder/services/locked_media_cryptor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class InMemorySecureStore extends NuvexSecureStore {
  final Map<String, String> _memory = {};

  @override
  Future<String?> read({required String key}) async => _memory[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _memory.remove(key);
    } else {
      _memory[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async {
    _memory.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('LockedMediaCryptor (AES-256-GCM)', () {
    late Uint8List masterKey;

    setUp(() {
      masterKey = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 7 + 13) % 256),
      );
    });

    test('Encrypt and decrypt in-memory bytes preserves exact data', () {
      final plaintext = utf8.encode('Nuvex Top Secret Photo Bytes 2026!');
      final encrypted = LockedMediaCryptor.encryptBytes(
        plaintext: Uint8List.fromList(plaintext),
        masterKey: masterKey,
      );

      // Verify NVXL magic header
      expect(encrypted.length, greaterThan(plaintext.length + 32));
      expect(encrypted[0], 0x4E); // 'N'
      expect(encrypted[1], 0x56); // 'V'
      expect(encrypted[2], 0x58); // 'X'
      expect(encrypted[3], 0x4C); // 'L'

      final decrypted = LockedMediaCryptor.decryptBytes(
        encryptedBytes: encrypted,
        masterKey: masterKey,
      );

      expect(utf8.decode(decrypted), 'Nuvex Top Secret Photo Bytes 2026!');
    });

    test('Tampering with encrypted bytes throws error', () {
      final plaintext = utf8.encode('Confidential Data');
      final encrypted = LockedMediaCryptor.encryptBytes(
        plaintext: Uint8List.fromList(plaintext),
        masterKey: masterKey,
      );

      // Tamper one byte in the payload
      encrypted[25] = encrypted[25] ^ 0xFF;

      expect(
        () => LockedMediaCryptor.decryptBytes(
          encryptedBytes: encrypted,
          masterKey: masterKey,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('File-based encryption and decryption roundtrip', () async {
      final tempDir = await Directory.systemTemp.createTemp('nuvex_crypt_test_');
      final sourceFile = File('${tempDir.path}/original.jpg');
      final encFile = File('${tempDir.path}/original.enc');
      final restoredFile = File('${tempDir.path}/restored.jpg');

      final sampleData = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 3) % 256),
      );
      await sourceFile.writeAsBytes(sampleData);

      await LockedMediaCryptor.encryptFile(
        sourceFile: sourceFile,
        destinationFile: encFile,
        masterKey: masterKey,
      );

      expect(await encFile.exists(), isTrue);

      await LockedMediaCryptor.decryptFile(
        encryptedFile: encFile,
        destinationFile: restoredFile,
        masterKey: masterKey,
      );

      expect(await restoredFile.exists(), isTrue);
      final restoredBytes = await restoredFile.readAsBytes();
      expect(restoredBytes, sampleData);

      await tempDir.delete(recursive: true);
    });
  });

  group('LockedFolderAuthService (PBKDF2 & Rate Limiting)', () {
    late InMemorySecureStore secureStore;
    late LockedFolderAuthService authService;

    setUp(() {
      secureStore = InMemorySecureStore();
      authService = LockedFolderAuthService(secureStore: secureStore);
    });

    test('Initial state: not configured', () async {
      expect(await authService.isSetupComplete(), isFalse);
    });

    test('PIN setup, verification, and master key retrieval', () async {
      await authService.setupPin('1234', enableBiometrics: false);
      expect(await authService.isSetupComplete(), isTrue);

      // Correct PIN verifies
      expect(await authService.verifyPin('1234'), isTrue);

      // Wrong PIN fails
      expect(await authService.verifyPin('9999'), isFalse);

      // Master key is 32 bytes (256-bit AES)
      final key = await authService.getMasterKey();
      expect(key, isNotNull);
      expect(key.length, 32);
    });

    test('5 consecutive failures triggers lockout', () async {
      await authService.setupPin('4321', enableBiometrics: false);

      for (int i = 0; i < 4; i++) {
        expect(await authService.verifyPin('0000'), isFalse);
        expect(await authService.getRemainingLockoutSeconds(), 0);
      }

      // 5th failure triggers lockout
      expect(await authService.verifyPin('0000'), isFalse);
      final remaining = await authService.getRemainingLockoutSeconds();
      expect(remaining, greaterThan(0));

      // Attempt while locked out should throw exception
      expect(
        () => authService.verifyPin('4321'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Database Gallery Exclusion for Locked Items', () {
    late Database testDb;
    late NuvexDatabase nuvexDb;

    setUp(() async {
      testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      nuvexDb = NuvexDatabase();
      await nuvexDb.initialize(overrideDb: testDb);
    });

    tearDown(() async {
      await testDb.close();
    });

    test('Locked files (isLocked=1) are completely excluded from normal gallery queries', () async {
      final publicPhoto = RemoteFile(
        id: 1,
        telegramChatId: 1000,
        telegramMessageId: 101,
        telegramFileId: 10101,
        name: 'vacation.jpg',
        sizeBytes: 1024,
        mimeType: 'image/jpeg',
        category: 'photos',
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        isLocked: false,
      );

      final lockedPhoto = RemoteFile(
        id: 2,
        telegramChatId: 1000,
        telegramMessageId: 102,
        telegramFileId: 10102,
        name: 'secret_document.jpg',
        sizeBytes: 2048,
        mimeType: 'image/jpeg',
        category: 'photos',
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        isLocked: true,
      );

      await nuvexDb.upsertFiles([publicPhoto, lockedPhoto]);

      // 1. getRecentMedia excludes locked
      final recent = await nuvexDb.getRecentMedia();
      expect(recent.length, 1);
      expect(recent.first.telegramMessageId, 101);

      // 2. getFilesByCategory('photos') excludes locked
      final photos = await nuvexDb.getFilesByCategory('photos');
      expect(photos.length, 1);
      expect(photos.first.telegramMessageId, 101);

      // 3. getFilesByCategory('locked') returns only locked files
      final locked = await nuvexDb.getFilesByCategory('locked');
      expect(locked.length, 1);
      expect(locked.first.telegramMessageId, 102);
      expect(locked.first.isLocked, isTrue);
    });
  });

  group('LockedFolderController Interaction & Selection Mode (Bug 2)', () {
    late Database testDb;
    late NuvexDatabase nuvexDb;
    late LockedFolderController controller;
    late RemoteFile lockedItem1;
    late RemoteFile lockedItem2;

    setUp(() async {
      testDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      nuvexDb = NuvexDatabase();
      await nuvexDb.initialize(overrideDb: testDb);

      final mediaRepo = MediaRepository(database: nuvexDb);
      final lockedRepo = LockedFolderRepository(
        database: nuvexDb,
        mediaRepository: mediaRepo,
      );
      final authService = LockedFolderAuthService(
        secureStore: InMemorySecureStore(),
      );

      controller = LockedFolderController(
        authService: authService,
        repository: lockedRepo,
      );

      lockedItem1 = RemoteFile(
        id: 1,
        telegramChatId: 1000,
        telegramMessageId: 501,
        telegramFileId: 50101,
        name: 'locked1.jpg',
        sizeBytes: 1024,
        mimeType: 'image/jpeg',
        category: 'photos',
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        isLocked: true,
      );

      lockedItem2 = RemoteFile(
        id: 2,
        telegramChatId: 1000,
        telegramMessageId: 502,
        telegramFileId: 50102,
        name: 'locked2.mp4',
        sizeBytes: 4096,
        mimeType: 'video/mp4',
        category: 'videos',
        createdAt: DateTime.now(),
        modifiedAt: DateTime.now(),
        isLocked: true,
      );
    });

    tearDown(() async {
      controller.dispose();
      await testDb.close();
    });

    test('Single-tap default state: selection mode is inactive so tapping views media', () {
      // Prior to long-press, selection mode is FALSE so tapping opens LockedMediaViewerScreen
      expect(controller.isSelectionMode, isFalse);
      expect(controller.selectedCount, 0);
      expect(controller.isFileSelected(501), isFalse);
    });

    test('Long-press enters explicit selection mode with initial item', () {
      controller.enterSelectionMode(lockedItem1);

      expect(controller.isSelectionMode, isTrue);
      expect(controller.selectedCount, 1);
      expect(controller.isFileSelected(501), isTrue);
      expect(controller.isFileSelected(502), isFalse);
    });

    test('While selection mode is active, taps select and deselect items', () {
      controller.enterSelectionMode(lockedItem1);
      expect(controller.selectedCount, 1);

      // Tap second item: selects it
      controller.toggleSelection(lockedItem2);
      expect(controller.selectedCount, 2);
      expect(controller.isFileSelected(502), isTrue);

      // Tap first item: deselects it
      controller.toggleSelection(lockedItem1);
      expect(controller.selectedCount, 1);
      expect(controller.isFileSelected(501), isFalse);
      expect(controller.isFileSelected(502), isTrue);
    });

    test('Exit selection mode clears selected items and restores normal viewing', () {
      controller.enterSelectionMode(lockedItem1);
      controller.toggleSelection(lockedItem2);
      expect(controller.isSelectionMode, isTrue);

      controller.exitSelectionMode();
      expect(controller.isSelectionMode, isFalse);
      expect(controller.selectedCount, 0);
      expect(controller.isFileSelected(501), isFalse);
      expect(controller.isFileSelected(502), isFalse);
    });

    test('Restoring selected items removes them from selection and updates locked collection', () async {
      await controller.setupPin('1234');
      expect(controller.isUnlocked, isTrue);

      final tempDir = await Directory.systemTemp.createTemp('nuvex_test_restore_ctrl_');
      final encFile = File('${tempDir.path}/501.enc');
      final encryptedBytes = LockedMediaCryptor.encryptBytes(
        plaintext: Uint8List.fromList([1, 2, 3]),
        masterKey: controller.masterKey!,
      );
      await encFile.writeAsBytes(encryptedBytes);

      final testItem = lockedItem1.copyWith(localPath: encFile.path);
      await nuvexDb.upsertFiles([testItem]);
      await controller.reload();

      // Enter selection mode on item
      controller.enterSelectionMode(testItem);
      expect(controller.selectedCount, 1);

      final restored = await controller.restoreSelectedItems();
      expect(restored.length, 1);
      expect(restored.first.telegramMessageId, 501);
      expect(restored.first.isLocked, isFalse);

      // Verify item removed from selection and selection mode exited
      expect(controller.selectedCount, 0);
      expect(controller.isSelectionMode, isFalse);

      // Verify item removed from locked folder collection
      expect(controller.lockedFiles.map((f) => f.telegramMessageId), isNot(contains(501)));

      // Verify item is now accessible in normal gallery query
      final recent = await nuvexDb.getRecentMedia();
      expect(recent.map((f) => f.telegramMessageId), contains(501));

      // And excluded from locked query
      final locked = await nuvexDb.getFilesByCategory('locked');
      expect(locked.map((f) => f.telegramMessageId), isNot(contains(501)));

      await tempDir.delete(recursive: true);
    });
  });
}
