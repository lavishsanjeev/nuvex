/// Real Telegram media and file record stored in the local SQLite database.
///
/// Strictly conforms to architecture.md Section 6 and Task 5 requirements:
/// - Real Telegram identifiers
/// - Real MIME type, size, date, width, height, duration
/// - Metadata-based classification category
class RemoteFile {
  final int id; // Primary key: telegramMessageId
  final int telegramChatId;
  final int telegramMessageId;
  final int telegramFileId;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String? thumbnailPath;
  final String? localPath;
  final bool remoteAvailable;
  final bool isFavorite;
  final bool isArchived;
  final bool isLocked;
  final double? latitude;
  final double? longitude;
  final int? durationMs;
  final int? width;
  final int? height;
  final String
  category; // 'photos', 'videos', 'documents', 'screenshots', 'stickers', etc.
  final bool isTrashed;
  final DateTime? trashedAt;
  final String? sha256;

  const RemoteFile({
    required this.id,
    required this.telegramChatId,
    required this.telegramMessageId,
    required this.telegramFileId,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.createdAt,
    required this.modifiedAt,
    this.thumbnailPath,
    this.localPath,
    this.remoteAvailable = true,
    this.isFavorite = false,
    this.isArchived = false,
    this.isLocked = false,
    this.latitude,
    this.longitude,
    this.durationMs,
    this.width,
    this.height,
    required this.category,
    this.isTrashed = false,
    this.trashedAt,
    this.sha256,
  });

  RemoteFile copyWith({
    int? id,
    int? telegramChatId,
    int? telegramMessageId,
    int? telegramFileId,
    String? name,
    String? mimeType,
    int? sizeBytes,
    DateTime? createdAt,
    DateTime? modifiedAt,
    String? thumbnailPath,
    String? localPath,
    bool? remoteAvailable,
    bool? isFavorite,
    bool? isArchived,
    bool? isLocked,
    double? latitude,
    double? longitude,
    int? durationMs,
    int? width,
    int? height,
    String? category,
    bool? isTrashed,
    DateTime? trashedAt,
    String? sha256,
  }) {
    return RemoteFile(
      id: id ?? this.id,
      telegramChatId: telegramChatId ?? this.telegramChatId,
      telegramMessageId: telegramMessageId ?? this.telegramMessageId,
      telegramFileId: telegramFileId ?? this.telegramFileId,
      name: name ?? this.name,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      localPath: localPath ?? this.localPath,
      remoteAvailable: remoteAvailable ?? this.remoteAvailable,
      isFavorite: isFavorite ?? this.isFavorite,
      isArchived: isArchived ?? this.isArchived,
      isLocked: isLocked ?? this.isLocked,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      durationMs: durationMs ?? this.durationMs,
      width: width ?? this.width,
      height: height ?? this.height,
      category: category ?? this.category,
      isTrashed: isTrashed ?? this.isTrashed,
      trashedAt: trashedAt ?? this.trashedAt,
      sha256: sha256 ?? this.sha256,
    );
  }

  bool get isPhoto => category == 'photos' || mimeType.startsWith('image/');
  bool get isVideo => category == 'videos' || mimeType.startsWith('video/');
  bool get isDocument => category == 'documents';
  bool get isScreenshot => category == 'screenshots';

  /// Returns remaining days before permanent 30-day deletion.
  int get daysRemainingInTrash {
    if (trashedAt == null) return 30;
    final elapsed = DateTime.now().difference(trashedAt!).inDays;
    final remaining = 30 - elapsed;
    return remaining < 0 ? 0 : remaining;
  }

  /// Whether this item has surpassed the 30-day retention window.
  bool get isExpiredInTrash {
    if (trashedAt == null) return false;
    return DateTime.now().difference(trashedAt!).inDays >= 30;
  }

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String? get formattedDuration {
    if (durationMs == null || durationMs == 0) return null;
    final totalSec = (durationMs! / 1000).round();
    final minutes = totalSec ~/ 60;
    final seconds = totalSec % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'telegramChatId': telegramChatId,
    'telegramMessageId': telegramMessageId,
    'telegramFileId': telegramFileId,
    'name': name,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'modifiedAt': modifiedAt.millisecondsSinceEpoch,
    'thumbnailPath': thumbnailPath,
    'localPath': localPath,
    'remoteAvailable': remoteAvailable ? 1 : 0,
    'isFavorite': isFavorite ? 1 : 0,
    'isArchived': isArchived ? 1 : 0,
    'isLocked': isLocked ? 1 : 0,
    'latitude': latitude,
    'longitude': longitude,
    'durationMs': durationMs,
    'width': width,
    'height': height,
    'category': category,
    'isTrashed': isTrashed ? 1 : 0,
    'trashedAt': trashedAt?.millisecondsSinceEpoch,
    'sha256': sha256,
  };

  factory RemoteFile.fromMap(Map<String, dynamic> map) => RemoteFile(
    id: map['id'] as int,
    telegramChatId: map['telegramChatId'] as int? ?? 0,
    telegramMessageId: map['telegramMessageId'] as int? ?? 0,
    telegramFileId: map['telegramFileId'] as int? ?? 0,
    name: map['name'] as String? ?? 'Unnamed file',
    mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
    sizeBytes: map['sizeBytes'] as int? ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      map['createdAt'] as int? ?? 0,
    ),
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(
      map['modifiedAt'] as int? ?? 0,
    ),
    thumbnailPath: map['thumbnailPath'] as String?,
    localPath: map['localPath'] as String?,
    remoteAvailable: (map['remoteAvailable'] as int? ?? 1) == 1,
    isFavorite: (map['isFavorite'] as int? ?? 0) == 1,
    isArchived: (map['isArchived'] as int? ?? 0) == 1,
    isLocked: (map['isLocked'] as int? ?? 0) == 1,
    latitude: (map['latitude'] as num?)?.toDouble(),
    longitude: (map['longitude'] as num?)?.toDouble(),
    durationMs: map['durationMs'] as int?,
    width: map['width'] as int?,
    height: map['height'] as int?,
    category: map['category'] as String? ?? 'documents',
    isTrashed: (map['isTrashed'] as int? ?? 0) == 1,
    trashedAt: map['trashedAt'] != null
        ? DateTime.fromMillisecondsSinceEpoch(map['trashedAt'] as int)
        : null,
    sha256: map['sha256'] as String?,
  );
}
