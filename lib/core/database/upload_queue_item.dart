/// Status of an item in the persistent SQLite upload queue.
enum UploadStatus {
  pending,
  uploading,
  completed,
  failed,
  cancelled,
  duplicate;

  static UploadStatus fromString(String val) {
    return UploadStatus.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => UploadStatus.pending,
    );
  }
}

/// A persistent upload item in the SQLite `upload_queue` table.
///
/// Complies strictly with Nuvex Upload Queue & Duplicate Detection requirements:
/// - Persistent SQLite storage surviving app restart
/// - Sequential uploads to Telegram using original-quality document upload
/// - Real byte progress reporting, filename, size, and status
/// - Cooperative cancellation and retry support
/// - Original-file SHA-256 duplicate detection
class UploadQueueItem {
  final int? id;
  final String filePath;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final UploadStatus status;
  final double progress;
  final String? sha256;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? telegramMessageId;

  const UploadQueueItem({
    this.id,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    this.status = UploadStatus.pending,
    this.progress = 0.0,
    this.sha256,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    this.telegramMessageId,
  });

  UploadQueueItem copyWith({
    int? id,
    String? filePath,
    String? fileName,
    int? fileSize,
    String? mimeType,
    UploadStatus? status,
    double? progress,
    String? sha256,
    String? errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? telegramMessageId,
  }) {
    return UploadQueueItem(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      sha256: sha256 ?? this.sha256,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      telegramMessageId: telegramMessageId ?? this.telegramMessageId,
    );
  }

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'filePath': filePath,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'status': status.name,
    'progress': progress,
    'sha256': sha256,
    'errorMessage': errorMessage,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'telegramMessageId': telegramMessageId,
  };

  factory UploadQueueItem.fromMap(Map<String, dynamic> map) => UploadQueueItem(
    id: map['id'] as int?,
    filePath: map['filePath'] as String? ?? '',
    fileName: map['fileName'] as String? ?? '',
    fileSize: map['fileSize'] as int? ?? 0,
    mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
    status: UploadStatus.fromString(map['status'] as String? ?? 'pending'),
    progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
    sha256: map['sha256'] as String?,
    errorMessage: map['errorMessage'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      map['createdAt'] as int? ?? 0,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      map['updatedAt'] as int? ?? 0,
    ),
    telegramMessageId: map['telegramMessageId'] as int?,
  );

  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
