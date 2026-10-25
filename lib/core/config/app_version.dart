/// Centralized app version information for Nuvex.
///
/// Kept in sync with `pubspec.yaml` (1.0.0+1).
class AppVersion {
  static const String currentVersion = '1.0.0';
  static const int currentBuildNumber = 1;

  static const String repositoryOwner = 'lavishsanjeev';
  static const String repositoryName = 'Nuvex';
  static const String repositoryUrl =
      'https://github.com/$repositoryOwner/$repositoryName';

  /// Raw manifest URL on default branch.
  static const String updateManifestUrl =
      'https://raw.githubusercontent.com/$repositoryOwner/$repositoryName/main/version.json';
}
