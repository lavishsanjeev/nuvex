import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'remote_file.dart';
import 'upload_queue_item.dart';

/// Central SQLite local database for Nuvex.
///
/// Implements local-first storage architecture conforming to architecture.md:
/// - Real metadata persistence for Telegram media and files
/// - Efficient indexing on timestamps and categories
/// - Real collection counts without fake data
class NuvexDatabase {
  static final NuvexDatabase _instance = NuvexDatabase._internal();
  factory NuvexDatabase() => _instance;
  NuvexDatabase._internal();

  Database? _db;

  Database get db {
    if (_db == null) {
      throw StateError(
        'NuvexDatabase has not been initialized. Call initialize() first.',
      );
    }
    return _db!;
  }

  bool get isInitialized => _db != null && _db!.isOpen;

  /// Initializes the local SQLite database.
  ///
  /// Can accept [overrideDb] for deterministic unit and widget testing.
  Future<void> initialize({Database? overrideDb}) async {
    if (_db != null && overrideDb == null) return;

    if (overrideDb != null) {
      _db = overrideDb;
      await _createTables(_db!);
      await _ensureMigrationColumns(_db!);
      return;
    }

    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'nuvex_storage.db');

      _db = await openDatabase(
        path,
        version: 2,
        onCreate: (db, version) async {
          await _createTables(db);
          await _ensureMigrationColumns(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await _ensureMigrationColumns(db);
          }
        },
        onOpen: (db) async {
          await _createTables(db);
          await _ensureMigrationColumns(db);
        },
      );
      debugPrint('[DB] SQLite database initialized at $path');
    } catch (e) {
      debugPrint('[DB] Error opening SQLite database: $e');
      rethrow;
    }
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS remote_files (
        id INTEGER PRIMARY KEY,
        telegramChatId INTEGER NOT NULL,
        telegramMessageId INTEGER NOT NULL UNIQUE,
        telegramFileId INTEGER NOT NULL,
        name TEXT NOT NULL,
        mimeType TEXT NOT NULL,
        sizeBytes INTEGER NOT NULL,
        createdAt INTEGER NOT NULL,
        modifiedAt INTEGER NOT NULL,
        thumbnailPath TEXT,
        localPath TEXT,
        remoteAvailable INTEGER NOT NULL DEFAULT 1,
        isFavorite INTEGER NOT NULL DEFAULT 0,
        isArchived INTEGER NOT NULL DEFAULT 0,
        isLocked INTEGER NOT NULL DEFAULT 0,
        latitude REAL,
        longitude REAL,
        durationMs INTEGER,
        width INTEGER,
        height INTEGER,
        category TEXT NOT NULL,
        isTrashed INTEGER NOT NULL DEFAULT 0,
        trashedAt INTEGER,
        sha256 TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_remote_files_created 
      ON remote_files(createdAt DESC)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_remote_files_category 
      ON remote_files(category)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_remote_files_name 
      ON remote_files(name COLLATE NOCASE)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS upload_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        filePath TEXT NOT NULL,
        fileName TEXT NOT NULL,
        fileSize INTEGER NOT NULL,
        mimeType TEXT NOT NULL,
        status TEXT NOT NULL,
        progress REAL NOT NULL DEFAULT 0.0,
        sha256 TEXT,
        errorMessage TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        telegramMessageId INTEGER
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_upload_queue_status 
      ON upload_queue(status)
    ''');

    // Clean up legacy recent_searches table if present
    await db.execute('DROP TABLE IF EXISTS recent_searches');

    await _ensureMigrationColumns(db);
  }

  /// Ensures required migration columns and tables exist.
  Future<void> _ensureMigrationColumns(Database db) async {
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='remote_files'",
      );
      if (tables.isNotEmpty) {
        final info = await db.rawQuery('PRAGMA table_info(remote_files)');
        final columnNames = info.map((r) => r['name'] as String).toSet();

        if (!columnNames.contains('isTrashed')) {
          await db.execute(
            'ALTER TABLE remote_files ADD COLUMN isTrashed INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (!columnNames.contains('trashedAt')) {
          await db.execute(
            'ALTER TABLE remote_files ADD COLUMN trashedAt INTEGER',
          );
        }
        if (!columnNames.contains('sha256')) {
          await db.execute('ALTER TABLE remote_files ADD COLUMN sha256 TEXT');
        }
        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_remote_files_trashed 
          ON remote_files(isTrashed, trashedAt)
        ''');
        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_remote_files_sha256 
          ON remote_files(sha256)
        ''');
        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_remote_files_gallery 
          ON remote_files(isTrashed, category, createdAt DESC)
        ''');
        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_remote_files_trashed_created 
          ON remote_files(isTrashed, createdAt DESC)
        ''');
      }

      await db.execute('''
        CREATE TABLE IF NOT EXISTS upload_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          filePath TEXT NOT NULL,
          fileName TEXT NOT NULL,
          fileSize INTEGER NOT NULL,
          mimeType TEXT NOT NULL,
          status TEXT NOT NULL,
          progress REAL NOT NULL DEFAULT 0.0,
          sha256 TEXT,
          errorMessage TEXT,
          createdAt INTEGER NOT NULL,
          updatedAt INTEGER NOT NULL,
          telegramMessageId INTEGER
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_upload_queue_status 
        ON upload_queue(status)
      ''');
    } catch (e) {
      debugPrint('[DB] Migration error checking columns: $e');
    }
  }

  /// Inserts or updates remote file metadata.
  Future<void> upsertFiles(List<RemoteFile> files) async {
    if (files.isEmpty) return;
    final database = db;

    final batch = database.batch();
    for (final file in files) {
      batch.rawInsert(
        '''
        INSERT INTO remote_files (
          id, telegramChatId, telegramMessageId, telegramFileId, name, mimeType,
          sizeBytes, createdAt, modifiedAt, thumbnailPath, localPath, remoteAvailable,
          isFavorite, isArchived, isLocked, latitude, longitude, durationMs, width, height, category,
          isTrashed, trashedAt, sha256
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(telegramMessageId) DO UPDATE SET
          name = excluded.name,
          mimeType = excluded.mimeType,
          sizeBytes = excluded.sizeBytes,
          createdAt = excluded.createdAt,
          modifiedAt = excluded.modifiedAt,
          thumbnailPath = COALESCE(excluded.thumbnailPath, remote_files.thumbnailPath),
          localPath = CASE 
            WHEN excluded.localPath IS NOT NULL AND excluded.localPath != '' THEN excluded.localPath 
            ELSE remote_files.localPath 
          END,
          remoteAvailable = excluded.remoteAvailable,
          isFavorite = CASE 
            WHEN excluded.isFavorite = 1 THEN 1 
            ELSE remote_files.isFavorite 
          END,
          isArchived = CASE 
            WHEN excluded.isArchived = 1 THEN 1 
            ELSE remote_files.isArchived 
          END,
          isLocked = CASE 
            WHEN excluded.isLocked = 1 THEN 1 
            ELSE remote_files.isLocked 
          END,
          latitude = COALESCE(excluded.latitude, remote_files.latitude),
          longitude = COALESCE(excluded.longitude, remote_files.longitude),
          durationMs = COALESCE(excluded.durationMs, remote_files.durationMs),
          width = COALESCE(excluded.width, remote_files.width),
          height = COALESCE(excluded.height, remote_files.height),
          category = excluded.category,
          isTrashed = remote_files.isTrashed,
          trashedAt = remote_files.trashedAt,
          sha256 = COALESCE(excluded.sha256, remote_files.sha256)
        ''',
        [
          file.id,
          file.telegramChatId,
          file.telegramMessageId,
          file.telegramFileId,
          file.name,
          file.mimeType,
          file.sizeBytes,
          file.createdAt.millisecondsSinceEpoch,
          file.modifiedAt.millisecondsSinceEpoch,
          file.thumbnailPath,
          file.localPath,
          file.remoteAvailable ? 1 : 0,
          file.isFavorite ? 1 : 0,
          file.isArchived ? 1 : 0,
          file.isLocked ? 1 : 0,
          file.latitude,
          file.longitude,
          file.durationMs,
          file.width,
          file.height,
          file.category,
          file.isTrashed ? 1 : 0,
          file.trashedAt?.millisecondsSinceEpoch,
          file.sha256,
        ],
      );
    }
    await batch.commit(noResult: true);
    debugPrint(
      '[DB_DIAGNOSTIC] [Stage 5] Upserted ${files.length} files to SQLite database',
    );
  }

  /// Returns the highest (newest) telegramMessageId currently stored in the database.
  Future<int?> getLatestTelegramMessageId() async {
    if (!isInitialized) return null;
    final res = await db.rawQuery(
      'SELECT MAX(telegramMessageId) as maxId FROM remote_files',
    );
    final val = res.firstOrNull?['maxId'];
    if (val is int) return val;
    if (val is num) return val.toInt();
    return null;
  }

  /// Checks which of the given telegramMessageIds already exist in the database.
  Future<Set<int>> getExistingTelegramMessageIds(List<int> ids) async {
    if (!isInitialized || ids.isEmpty) return {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final res = await db.rawQuery(
      'SELECT telegramMessageId FROM remote_files WHERE telegramMessageId IN ($placeholders)',
      ids,
    );
    final Set<int> existing = {};
    for (final r in res) {
      final id = r['telegramMessageId'];
      if (id is int) existing.add(id);
      if (id is num) existing.add(id.toInt());
    }
    return existing;
  }

  /// Retrieves recent media (photos and videos) ordered by creation date descending.
  Future<List<RemoteFile>> getRecentMedia({int? limit, int offset = 0}) async {
    final database = db;
    final rows = await database.query(
      'remote_files',
      where: 'category IN (?, ?, ?) AND isTrashed = 0 AND isLocked = 0',
      whereArgs: ['photos', 'videos', 'screenshots'],
      orderBy: 'createdAt DESC',
      limit: limit,
      offset: offset,
    );

    debugPrint(
      '[DB_DIAGNOSTIC] [Stage 6] getRecentMedia returned ${rows.length} rows (limit: $limit, offset: $offset)',
    );

    return rows.map((r) => RemoteFile.fromMap(r)).toList();
  }

  /// Retrieves files classified into a specific category.
  Future<List<RemoteFile>> getFilesByCategory(
    String category, {
    int limit = 50,
    int offset = 0,
  }) async {
    if (!isInitialized) return [];
    final database = db;

    if (category == 'trash' || category == 'recently_deleted') {
      final rows = await database.query(
        'remote_files',
        where: 'isTrashed = 1',
        orderBy: 'trashedAt DESC, createdAt DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => RemoteFile.fromMap(r)).toList();
    }

    if (category == 'largest_files') {
      final rows = await database.query(
        'remote_files',
        where: 'isTrashed = 0 AND isLocked = 0',
        orderBy: 'sizeBytes DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => RemoteFile.fromMap(r)).toList();
    }

    if (category == 'recently_added') {
      final cutoff = DateTime.now()
          .subtract(const Duration(days: 7))
          .millisecondsSinceEpoch;
      final rows = await database.query(
        'remote_files',
        where: 'createdAt >= ? AND isTrashed = 0 AND isLocked = 0',
        whereArgs: [cutoff],
        orderBy: 'createdAt DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => RemoteFile.fromMap(r)).toList();
    }

    if (category == 'archive') {
      final rows = await database.query(
        'remote_files',
        where: 'isArchived = 1 AND isTrashed = 0 AND isLocked = 0',
        orderBy: 'createdAt DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => RemoteFile.fromMap(r)).toList();
    }

    if (category == 'locked') {
      final rows = await database.query(
        'remote_files',
        where: 'isLocked = 1 AND isTrashed = 0',
        orderBy: 'createdAt DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => RemoteFile.fromMap(r)).toList();
    }

    if (category == 'favorites') {
      final rows = await database.query(
        'remote_files',
        where: 'isFavorite = 1 AND isTrashed = 0 AND isLocked = 0',
        orderBy: 'createdAt DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => RemoteFile.fromMap(r)).toList();
    }

    if (category == 'places') {
      final rows = await database.query(
        'remote_files',
        where:
            'latitude IS NOT NULL AND longitude IS NOT NULL AND isTrashed = 0 AND isLocked = 0',
        orderBy: 'createdAt DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => RemoteFile.fromMap(r)).toList();
    }

    if (category == 'moments') {
      final explicit = await database.query(
        'remote_files',
        where: "category = 'moments' AND isTrashed = 0 AND isLocked = 0",
        orderBy: 'createdAt DESC',
        limit: limit,
        offset: offset,
      );
      if (explicit.isNotEmpty) {
        return explicit.map((r) => RemoteFile.fromMap(r)).toList();
      }
      return _getRecentMomentFiles(limit: limit, offset: offset);
    }

    final rows = await database.query(
      'remote_files',
      where: 'category = ? AND isTrashed = 0 AND isLocked = 0',
      whereArgs: [category],
      orderBy: 'createdAt DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => RemoteFile.fromMap(r)).toList();
  }

  /// Helper to query media files from the most recent meaningful date cluster.
  Future<List<RemoteFile>> _getRecentMomentFiles({
    int limit = 50,
    int offset = 0,
  }) async {
    if (!isInitialized) return [];
    final database = db;

    // Fetch the most recent media candidates
    final rows = await database.query(
      'remote_files',
      where:
          "category IN ('photos', 'videos', 'screenshots') AND isTrashed = 0",
      orderBy: 'createdAt DESC',
      limit: 200,
    );
    if (rows.isEmpty) return [];

    // Group recent media by calendar day to find the most recent meaningful cluster (>= 2 items)
    final grouped = <String, List<RemoteFile>>{};
    for (final r in rows) {
      final file = RemoteFile.fromMap(r);
      final d = file.createdAt;
      final key = '${d.year}-${d.month}-${d.day}';
      grouped.putIfAbsent(key, () => []).add(file);
    }

    for (final entry in grouped.entries) {
      if (entry.value.length >= 2) {
        final cluster = entry.value;
        if (offset >= cluster.length) return [];
        return cluster.skip(offset).take(limit).toList();
      }
    }

    // Insufficient data to form a moment cluster
    return [];
  }

  /// Retrieves a single representative file for a collection category.
  Future<RemoteFile?> getRepresentativeFile(String category) async {
    if (!isInitialized) return null;
    final database = db;

    if (category == 'trash' || category == 'recently_deleted') {
      final rowsWithThumb = await database.query(
        'remote_files',
        where: "isTrashed = 1 AND thumbnailPath IS NOT NULL AND thumbnailPath != ''",
        orderBy: 'trashedAt DESC, createdAt DESC',
        limit: 1,
      );
      if (rowsWithThumb.isNotEmpty) {
        return RemoteFile.fromMap(rowsWithThumb.first);
      }
      final anyTrash = await database.query(
        'remote_files',
        where: 'isTrashed = 1',
        orderBy: 'trashedAt DESC, createdAt DESC',
        limit: 1,
      );
      return anyTrash.isNotEmpty ? RemoteFile.fromMap(anyTrash.first) : null;
    }

    if (category == 'documents') {
      final rowsWithThumb = await database.query(
        'remote_files',
        where: "category = 'documents' AND isTrashed = 0 AND thumbnailPath IS NOT NULL AND thumbnailPath != ''",
        orderBy: 'createdAt DESC',
        limit: 1,
      );
      if (rowsWithThumb.isNotEmpty) {
        return RemoteFile.fromMap(rowsWithThumb.first);
      }
    } else if (category == 'places') {
      final rowsWithThumb = await database.query(
        'remote_files',
        where: "latitude IS NOT NULL AND longitude IS NOT NULL AND isTrashed = 0 AND thumbnailPath IS NOT NULL AND thumbnailPath != ''",
        orderBy: 'createdAt DESC',
        limit: 1,
      );
      if (rowsWithThumb.isNotEmpty) {
        return RemoteFile.fromMap(rowsWithThumb.first);
      }
    } else if (category == 'stickers') {
      final rowsWithThumb = await database.query(
        'remote_files',
        where: "category = 'stickers' AND isTrashed = 0 AND thumbnailPath IS NOT NULL AND thumbnailPath != ''",
        orderBy: 'createdAt DESC',
        limit: 1,
      );
      if (rowsWithThumb.isNotEmpty) {
        return RemoteFile.fromMap(rowsWithThumb.first);
      }
    } else if (category == 'moments') {
      // 1. Check for explicit moments category first (backward compatibility)
      final explicitThumb = await database.query(
        'remote_files',
        where: "category = 'moments' AND isTrashed = 0 AND thumbnailPath IS NOT NULL AND thumbnailPath != ''",
        orderBy: 'createdAt DESC',
        limit: 1,
      );
      if (explicitThumb.isNotEmpty) {
        return RemoteFile.fromMap(explicitThumb.first);
      }
      final explicitFiles = await database.query(
        'remote_files',
        where: "category = 'moments' AND isTrashed = 0 AND isLocked = 0",
        orderBy: 'createdAt DESC',
        limit: 1,
      );
      if (explicitFiles.isNotEmpty) {
        return RemoteFile.fromMap(explicitFiles.first);
      }

      // 2. Derive from most recent meaningful date cluster of real media
      final momentFiles = await _getRecentMomentFiles(limit: 50);
      if (momentFiles.isNotEmpty) {
        for (final f in momentFiles) {
          if (f.thumbnailPath != null && f.thumbnailPath!.isNotEmpty) {
            return f;
          }
        }
        return momentFiles.first;
      }
      return null;
    }

    final files = await getFilesByCategory(category, limit: 1);
    return files.firstOrNull;
  }

  /// Computes real collection counts derived directly from database metadata.
  Future<Map<String, int>> getCollectionCounts() async {
    if (!isInitialized) return {};
    final database = db;
    final Map<String, int> counts = {
      'documents': 0,
      'places': 0,
      'stickers': 0,
      'moments': 0,
      'screenshots': 0,
      'videos': 0,
      'recently_added': 0,
      'creations': 0,
      'archive': 0,
      'locked': 0,
      'recently_deleted': 0,
      'trash': 0,
    };

    final rows = await database.rawQuery('''
      SELECT category, COUNT(*) as count 
      FROM remote_files 
      WHERE isTrashed = 0 AND isLocked = 0
      GROUP BY category
    ''');

    for (final r in rows) {
      final cat = r['category'] as String?;
      final count = (r['count'] as num?)?.toInt() ?? 0;
      if (cat != null && counts.containsKey(cat)) {
        counts[cat] = count;
      }
    }

    final cutoff = DateTime.now()
        .subtract(const Duration(days: 7))
        .millisecondsSinceEpoch;

    // Single unified aggregation query for all special flag and temporal counts
    final aggregateRes = await database.rawQuery(
      '''
      SELECT 
        SUM(CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL AND isTrashed = 0 AND isLocked = 0 THEN 1 ELSE 0 END) as places_count,
        SUM(CASE WHEN category = 'moments' AND isTrashed = 0 AND isLocked = 0 THEN 1 ELSE 0 END) as moments_count,
        SUM(CASE WHEN createdAt >= ? AND isTrashed = 0 AND isLocked = 0 THEN 1 ELSE 0 END) as recent_count,
        SUM(CASE WHEN isArchived = 1 AND isTrashed = 0 AND isLocked = 0 THEN 1 ELSE 0 END) as archive_count,
        SUM(CASE WHEN isLocked = 1 AND isTrashed = 0 THEN 1 ELSE 0 END) as locked_count,
        SUM(CASE WHEN isFavorite = 1 AND isTrashed = 0 AND isLocked = 0 THEN 1 ELSE 0 END) as fav_count,
        SUM(CASE WHEN isTrashed = 1 THEN 1 ELSE 0 END) as trash_count
      FROM remote_files
    ''',
      [cutoff],
    );

    final row = aggregateRes.firstOrNull;
    if (row != null) {
      counts['places'] = (row['places_count'] as num?)?.toInt() ?? 0;
      final expMoments = (row['moments_count'] as num?)?.toInt() ?? 0;
      if (expMoments > 0) {
        counts['moments'] = expMoments;
      } else {
        final momentFiles = await _getRecentMomentFiles(limit: 50);
        counts['moments'] = momentFiles.length;
      }
      counts['recently_added'] = (row['recent_count'] as num?)?.toInt() ?? 0;
      counts['archive'] = (row['archive_count'] as num?)?.toInt() ?? 0;
      counts['locked'] = (row['locked_count'] as num?)?.toInt() ?? 0;
      counts['favorites'] = (row['fav_count'] as num?)?.toInt() ?? 0;
      final trashCount = (row['trash_count'] as num?)?.toInt() ?? 0;
      counts['recently_deleted'] = trashCount;
      counts['trash'] = trashCount;
    }

    return counts;
  }

  /// Returns the maximum Telegram message ID saved locally for incremental sync.
  Future<int?> getLatestMessageId() async {
    final database = db;
    final rows = await database.rawQuery(
      'SELECT MAX(telegramMessageId) as maxId FROM remote_files',
    );
    final maxId = rows.firstOrNull?['maxId'] as int?;
    return maxId;
  }

  /// Moves a media record to Trash by setting isTrashed = 1 and trashedAt = timestamp.
  Future<void> moveToTrash(int telegramMessageId, {int? trashedAtMs}) async {
    final database = db;
    final now = trashedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    await database.update(
      'remote_files',
      {'isTrashed': 1, 'trashedAt': now},
      where: 'telegramMessageId = ?',
      whereArgs: [telegramMessageId],
    );
  }

  /// Restores a trashed media record back to active status (isTrashed = 0, trashedAt = NULL).
  Future<void> restoreFromTrash(int telegramMessageId) async {
    final database = db;
    await database.update(
      'remote_files',
      {'isTrashed': 0, 'trashedAt': null},
      where: 'telegramMessageId = ?',
      whereArgs: [telegramMessageId],
    );
  }

  /// Updates the lock state of a media record directly in SQLite.
  /// Bypasses upsert conflict resolution so that restore operations reliably set isLocked = 0.
  Future<void> updateFileLockState(
    int telegramMessageId, {
    required bool isLocked,
    String? localPath,
    String? thumbnailPath,
  }) async {
    final database = db;
    final Map<String, dynamic> values = {
      'isLocked': isLocked ? 1 : 0,
      'modifiedAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (localPath != null) {
      values['localPath'] = localPath;
    }
    if (thumbnailPath != null) {
      values['thumbnailPath'] = thumbnailPath;
    }
    await database.update(
      'remote_files',
      values,
      where: 'telegramMessageId = ?',
      whereArgs: [telegramMessageId],
    );
  }

  /// Retrieves trashed media records ordered by deletion timestamp descending.
  Future<List<RemoteFile>> getTrashedMedia({int? limit, int offset = 0}) async {
    final database = db;
    final rows = await database.query(
      'remote_files',
      where: 'isTrashed = 1',
      orderBy: 'trashedAt DESC, createdAt DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => RemoteFile.fromMap(r)).toList();
  }

  /// Returns total count of items currently in Trash.
  Future<int> getTrashedCount() async {
    final database = db;
    final res = await database.rawQuery(
      'SELECT COUNT(*) as count FROM remote_files WHERE isTrashed = 1',
    );
    return (res.firstOrNull?['count'] as num?)?.toInt() ?? 0;
  }

  /// Retrieves trashed files that have exceeded the retention duration (default 30 days).
  Future<List<RemoteFile>> getExpiredTrashedFiles({
    Duration retention = const Duration(days: 30),
  }) async {
    final database = db;
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    final rows = await database.query(
      'remote_files',
      where: 'isTrashed = 1 AND trashedAt IS NOT NULL AND trashedAt <= ?',
      whereArgs: [cutoff],
    );
    return rows.map((r) => RemoteFile.fromMap(r)).toList();
  }

  /// Deletes a file record by Telegram message ID.
  Future<void> deleteFile(int telegramMessageId) async {
    final database = db;
    await database.delete(
      'remote_files',
      where: 'telegramMessageId = ?',
      whereArgs: [telegramMessageId],
    );
  }

  /// Computes real storage statistics derived directly from SQLite metadata.
  Future<NuvexStorageStats> getStorageStats() async {
    final database = db;
    final rows = await database.rawQuery('''
      SELECT category, COUNT(*) as file_count, SUM(sizeBytes) as total_bytes
      FROM remote_files
      WHERE isTrashed = 0 AND isLocked = 0
      GROUP BY category
    ''');

    int photosCount = 0;
    int photosBytes = 0;
    int videosCount = 0;
    int videosBytes = 0;
    int docsCount = 0;
    int docsBytes = 0;
    int otherCount = 0;
    int otherBytes = 0;

    for (final r in rows) {
      final cat = (r['category'] as String?)?.toLowerCase() ?? 'other';
      final count = (r['file_count'] as num?)?.toInt() ?? 0;
      final bytes = (r['total_bytes'] as num?)?.toInt() ?? 0;

      if (cat == 'photos') {
        photosCount += count;
        photosBytes += bytes;
      } else if (cat == 'videos') {
        videosCount += count;
        videosBytes += bytes;
      } else if (cat == 'documents') {
        docsCount += count;
        docsBytes += bytes;
      } else {
        otherCount += count;
        otherBytes += bytes;
      }
    }

    final totalCount = photosCount + videosCount + docsCount + otherCount;
    final totalBytes = photosBytes + videosBytes + docsBytes + otherBytes;

    return NuvexStorageStats(
      photos: CategoryStorageStat(count: photosCount, totalBytes: photosBytes),
      videos: CategoryStorageStat(count: videosCount, totalBytes: videosBytes),
      documents: CategoryStorageStat(count: docsCount, totalBytes: docsBytes),
      other: CategoryStorageStat(count: otherCount, totalBytes: otherBytes),
      totalCount: totalCount,
      totalBytes: totalBytes,
    );
  }

  // ── Duplicate Detection Methods ──

  /// Finds an existing non-trashed file by its SHA-256 hash.
  Future<RemoteFile?> findFileBySha256(String hash) async {
    final database = db;
    final rows = await database.query(
      'remote_files',
      where: 'sha256 = ? AND isTrashed = 0',
      whereArgs: [hash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RemoteFile.fromMap(rows.first);
  }

  /// Checks whether an identical file hash exists in either remote_files or completed upload_queue.
  Future<bool> hasFileWithSha256(String hash) async {
    final database = db;
    final existingFile = await findFileBySha256(hash);
    if (existingFile != null) return true;

    final queueRows = await database.query(
      'upload_queue',
      where: "sha256 = ? AND status = 'completed'",
      whereArgs: [hash],
      limit: 1,
    );
    return queueRows.isNotEmpty;
  }

  // ── Upload Queue Persistence Methods ──

  /// Inserts a new upload queue item, returning the generated row id.
  Future<int> insertUploadQueueItem(UploadQueueItem item) async {
    final database = db;
    return database.insert('upload_queue', item.toMap());
  }

  /// Updates an existing upload queue item by ID.
  Future<void> updateUploadQueueItem(UploadQueueItem item) async {
    if (item.id == null) return;
    final database = db;
    await database.update(
      'upload_queue',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  /// Retrieves all upload queue items ordered chronologically.
  Future<List<UploadQueueItem>> getUploadQueue() async {
    if (!isInitialized) return [];
    final database = db;
    final rows = await database.query('upload_queue', orderBy: 'createdAt ASC');
    return rows.map((r) => UploadQueueItem.fromMap(r)).toList();
  }

  /// Retrieves a single upload queue item by ID.
  Future<UploadQueueItem?> getUploadQueueItem(int id) async {
    if (!isInitialized) return null;
    final database = db;
    final rows = await database.query(
      'upload_queue',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UploadQueueItem.fromMap(rows.first);
  }

  /// Deletes a queue item by ID.
  Future<void> deleteUploadQueueItem(int id) async {
    if (!isInitialized) return;
    final database = db;
    await database.delete('upload_queue', where: 'id = ?', whereArgs: [id]);
  }

  /// Resets any items left in 'uploading' status back to 'pending' upon app restart.
  /// Strictly satisfies requirement: "Queue must survive app restart."
  Future<void> resetUploadingToPending() async {
    if (!isInitialized) return;
    final database = db;
    await database.update('upload_queue', {
      'status': 'pending',
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    }, where: "status = 'uploading'");
  }

  /// Closes database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

/// Statistics for a single storage category.
class CategoryStorageStat {
  final int count;
  final int totalBytes;

  const CategoryStorageStat({required this.count, required this.totalBytes});
}

/// Aggregated storage statistics derived from real SQLite metadata.
class NuvexStorageStats {
  final CategoryStorageStat photos;
  final CategoryStorageStat videos;
  final CategoryStorageStat documents;
  final CategoryStorageStat other;
  final int totalCount;
  final int totalBytes;

  const NuvexStorageStats({
    required this.photos,
    required this.videos,
    required this.documents,
    required this.other,
    required this.totalCount,
    required this.totalBytes,
  });

  static const NuvexStorageStats empty = NuvexStorageStats(
    photos: CategoryStorageStat(count: 0, totalBytes: 0),
    videos: CategoryStorageStat(count: 0, totalBytes: 0),
    documents: CategoryStorageStat(count: 0, totalBytes: 0),
    other: CategoryStorageStat(count: 0, totalBytes: 0),
    totalCount: 0,
    totalBytes: 0,
  );
}
