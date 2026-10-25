import 'package:flutter/foundation.dart';

/// Represents a semantically comparable application version (e.g. 1.2.3+4).
@immutable
class SemanticVersion implements Comparable<SemanticVersion> {
  final int major;
  final int minor;
  final int patch;
  final int? buildNumber;

  const SemanticVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.buildNumber,
  });

  /// Parses strings like '1.2.3', 'v1.2.3', or '1.2.3+4'.
  factory SemanticVersion.parse(String input) {
    var clean = input.trim();
    if (clean.startsWith('v') || clean.startsWith('V')) {
      clean = clean.substring(1).trim();
    }

    int? build;
    if (clean.contains('+')) {
      final parts = clean.split('+');
      clean = parts[0];
      build = int.tryParse(parts[1]);
    }

    final segments = clean.split('.');
    final major = segments.isNotEmpty ? int.tryParse(segments[0]) ?? 0 : 0;
    final minor = segments.length > 1 ? int.tryParse(segments[1]) ?? 0 : 0;
    final patch = segments.length > 2 ? int.tryParse(segments[2]) ?? 0 : 0;

    return SemanticVersion(
      major: major,
      minor: minor,
      patch: patch,
      buildNumber: build,
    );
  }

  @override
  int compareTo(SemanticVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    if (buildNumber != null && other.buildNumber != null) {
      return buildNumber!.compareTo(other.buildNumber!);
    }
    return 0;
  }

  bool operator >(SemanticVersion other) => compareTo(other) > 0;
  bool operator <(SemanticVersion other) => compareTo(other) < 0;
  bool operator >=(SemanticVersion other) => compareTo(other) >= 0;
  bool operator <=(SemanticVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SemanticVersion &&
          runtimeType == other.runtimeType &&
          major == other.major &&
          minor == other.minor &&
          patch == other.patch &&
          buildNumber == other.buildNumber;

  @override
  int get hashCode =>
      major.hashCode ^ minor.hashCode ^ patch.hashCode ^ buildNumber.hashCode;

  @override
  String toString() {
    final base = '$major.$minor.$patch';
    return buildNumber != null ? '$base+$buildNumber' : base;
  }
}

/// Metadata payload retrieved from update discovery manifest.
@immutable
class UpdateManifest {
  final SemanticVersion latestVersion;
  final SemanticVersion minSupportedVersion;
  final bool isMandatory;
  final String? releaseDate;
  final String? releaseNotes;
  final String downloadUrl;
  final String apkUrl;

  const UpdateManifest({
    required this.latestVersion,
    required this.minSupportedVersion,
    required this.isMandatory,
    this.releaseDate,
    this.releaseNotes,
    required this.downloadUrl,
    required this.apkUrl,
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final latestStr = json['latest_version'] as String? ?? '0.0.0';
    final latestBuild = json['build_number'] as int?;
    final latest = SemanticVersion.parse(latestStr);
    final effectiveLatest = SemanticVersion(
      major: latest.major,
      minor: latest.minor,
      patch: latest.patch,
      buildNumber: latestBuild ?? latest.buildNumber,
    );

    final minStr = json['min_supported_version'] as String? ?? '0.0.0';
    final minVersion = SemanticVersion.parse(minStr);

    final mandatory = json['is_mandatory'] as bool? ?? false;
    final date = json['release_date'] as String?;
    final notes = json['release_notes'] as String?;
    final download = json['download_url'] as String? ?? '';
    final apk = json['apk_url'] as String? ?? download;

    return UpdateManifest(
      latestVersion: effectiveLatest,
      minSupportedVersion: minVersion,
      isMandatory: mandatory,
      releaseDate: date,
      releaseNotes: notes,
      downloadUrl: download,
      apkUrl: apk,
    );
  }

  /// Checks if an update is available compared to [current].
  bool hasUpdate(SemanticVersion current) => latestVersion > current;

  /// Checks if update is mandatory for [current].
  bool isForced(SemanticVersion current) =>
      isMandatory || current < minSupportedVersion;
}
