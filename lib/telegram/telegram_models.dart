import 'dart:convert';
import 'dart:typed_data';

import '../core/database/remote_file.dart';

/// Representation of an authorized Telegram user.
///
/// Keeps user metadata clean and UI-ready without exposing MTProto internals.
class NuvexTelegramUser {
  final int id;
  final String firstName;
  final String? lastName;
  final String? username;
  final String? phone;

  const NuvexTelegramUser({
    required this.id,
    required this.firstName,
    this.lastName,
    this.username,
    this.phone,
  });

  String get displayName {
    if (lastName != null && lastName!.trim().isNotEmpty) {
      return '$firstName $lastName';
    }
    return firstName;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'firstName': firstName,
    'lastName': lastName,
    'username': username,
    'phone': phone,
  };

  factory NuvexTelegramUser.fromJson(Map<String, dynamic> json) =>
      NuvexTelegramUser(
        id: json['id'] as int,
        firstName: json['firstName'] as String,
        lastName: json['lastName'] as String?,
        username: json['username'] as String?,
        phone: json['phone'] as String?,
      );

  String serialize() => jsonEncode(toJson());

  static NuvexTelegramUser? deserialize(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final map = jsonDecode(source) as Map<String, dynamic>;
      return NuvexTelegramUser.fromJson(map);
    } catch (_) {
      return null;
    }
  }
}

/// Result of sending a Telegram verification code.
class AuthSendCodeResult {
  final bool isSuccess;
  final String? phoneCodeHash;
  final int? timeout;
  final String? errorMessage;

  const AuthSendCodeResult.success({required this.phoneCodeHash, this.timeout})
    : isSuccess = true,
      errorMessage = null;

  const AuthSendCodeResult.failure(this.errorMessage)
    : isSuccess = false,
      phoneCodeHash = null,
      timeout = null;
}

/// Status outcomes of a sign-in or 2FA verification attempt.
enum AuthSignInStatus { authorized, passwordNeeded, failure }

/// Result of a Telegram signIn or checkPassword operation.
class AuthSignInResult {
  final AuthSignInStatus status;
  final NuvexTelegramUser? user;
  final String? errorMessage;

  const AuthSignInResult.authorized(this.user)
    : status = AuthSignInStatus.authorized,
      errorMessage = null;

  const AuthSignInResult.passwordNeeded()
    : status = AuthSignInStatus.passwordNeeded,
      user = null,
      errorMessage = null;

  const AuthSignInResult.failure(this.errorMessage)
    : status = AuthSignInStatus.failure,
      user = null;

  bool get isAuthorized => status == AuthSignInStatus.authorized;
  bool get isPasswordNeeded => status == AuthSignInStatus.passwordNeeded;
  bool get isFailure => status == AuthSignInStatus.failure;
}

/// Token allowing cooperative cancellation of an in-progress Telegram upload.
class TelegramUploadCancelToken {
  bool _isCancelled = false;
  String? _reason;

  bool get isCancelled => _isCancelled;
  String? get reason => _reason;

  void cancel([String? reason]) {
    _isCancelled = true;
    _reason = reason;
  }

  void throwIfCancelled() {
    if (_isCancelled) {
      throw TelegramUploadCancelledException(_reason);
    }
  }
}

/// Exception thrown when a Telegram upload is cancelled.
class TelegramUploadCancelledException implements Exception {
  final String? message;
  const TelegramUploadCancelledException([this.message]);

  @override
  String toString() => message == null
      ? 'TelegramUploadCancelledException: Upload was cancelled.'
      : 'TelegramUploadCancelledException: $message';
}

/// Metadata and identifiers for a file uploaded to Telegram Saved Messages.
class TelegramUploadResult {
  final int messageId;
  final int fileId;
  final int accessHash;
  final Uint8List fileReference;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final DateTime date;
  final int? width;
  final int? height;
  final int? durationMs;
  final String category;
  final int? randomId;
  final String? sha256;

  const TelegramUploadResult({
    required this.messageId,
    required this.fileId,
    required this.accessHash,
    required this.fileReference,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.date,
    this.width,
    this.height,
    this.durationMs,
    required this.category,
    this.randomId,
    this.sha256,
  });

  /// Maps this upload result to a Nuvex [RemoteFile] record for database persistence.
  RemoteFile toRemoteFile({
    String? localPath,
    String? thumbnailPath,
    String? sha256,
  }) {
    return RemoteFile(
      id: messageId,
      telegramChatId: 0,
      telegramMessageId: messageId,
      telegramFileId: fileId,
      name: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      createdAt: date,
      modifiedAt: date,
      thumbnailPath: thumbnailPath,
      localPath: localPath,
      remoteAvailable: true,
      category: category,
      width: width,
      height: height,
      durationMs: durationMs,
      sha256: sha256 ?? this.sha256,
    );
  }
}
