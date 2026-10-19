import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mongo_wire/mongo_wire.dart'
    show CancelToken, MongoCancelledError;

import 'native.dart';

/// Set by CI with `--dart-define=APP_VERSION=0.1.N`; `dev` for local builds.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

const releasesRepo = 'FahadDhruba/mongomobile';

/// `v0.1.7` or `0.1.7` → [0, 1, 7]; null when it isn't a version.
List<int>? parseVersion(String s) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(s.trim());
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
}

int compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return 0;
}

/// The latest published release.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.pageUrl,
    required this.apkUrl,
    required this.apkSize,
    this.sha256Url,
  });

  final List<int> version;
  final String tag;
  final String notes;
  final String pageUrl;
  final String apkUrl;
  final int apkSize;
  final String? sha256Url;

  String get versionName => version.join('.');

  /// Reads a GitHub "latest release" response. Null when it has no APK.
  static ReleaseInfo? fromGitHub(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String? ?? '';
    final version = parseVersion(tag);
    if (version == null) return null;
    final assets = (json['assets'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    Map<String, dynamic>? apk;
    String? sha;
    for (final a in assets) {
      final name = a['name'] as String? ?? '';
      if (name.endsWith('.apk')) apk = a;
      if (name.endsWith('.apk.sha256')) {
        sha = a['browser_download_url'] as String?;
      }
    }
    if (apk == null) return null;
    return ReleaseInfo(
      version: version,
      tag: tag,
      notes: (json['body'] as String? ?? '').trim(),
      pageUrl: json['html_url'] as String? ?? '',
      apkUrl: apk['browser_download_url'] as String,
      apkSize: (apk['size'] as num?)?.toInt() ?? 0,
      sha256Url: sha,
    );
  }
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Checks GitHub Releases for a newer version, downloads it and starts the
/// system installer. Releases are signed with the same key, so Android
/// installs them over the running app and keeps its data.
class Updater {
  Updater({
    HttpClient? http,
    NativeInstaller? installer,
    this.currentVersion = appVersion,
  }) : _http =
           http ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _installer = installer ?? NativeInstaller();

  final HttpClient _http;
  final NativeInstaller _installer;
  final String currentVersion;

  /// Null for local development builds, which can't be compared.
  List<int>? get current => parseVersion(currentVersion);

  Future<ReleaseInfo?> latestRelease() async {
    final req = await _http.getUrl(
      Uri.parse('https://api.github.com/repos/$releasesRepo/releases/latest'),
    );
    req.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'MongoMobile/$currentVersion');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw UpdateException(
        'GitHub answered ${res.statusCode} while checking for updates',
      );
    }
    return ReleaseInfo.fromGitHub(jsonDecode(body) as Map<String, dynamic>);
  }

  /// The latest release when it is newer than this build, else null.
  Future<ReleaseInfo?> availableUpdate() async {
    final cur = current;
    if (cur == null) return null;
    final latest = await latestRelease();
    if (latest == null || compareVersions(latest.version, cur) <= 0) {
      return null;
    }
    return latest;
  }

  Future<String?> _expectedSha256(ReleaseInfo r) async {
    final url = r.sha256Url;
    if (url == null) return null;
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    final text = await res.transform(utf8.decoder).join();
    final hash = text.trim().split(RegExp(r'\s+')).first.toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ? hash : null;
  }

  /// Downloads the APK into the app's cache, checks its SHA-256 against the
  /// release's checksum file, and returns the file path.
  Future<String> download(
    ReleaseInfo r, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final expected = await _expectedSha256(r);
    final dir = Directory('${await _installer.cacheDir()}/updates');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final file = File('${dir.path}/mongomobile-${r.versionName}.apk');
    final req = await _http.getUrl(Uri.parse(r.apkUrl));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw UpdateException('Download failed: HTTP ${res.statusCode}');
    }
    final total = res.contentLength > 0 ? res.contentLength : r.apkSize;
    final sink = file.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    try {
      await for (final chunk in res) {
        if (cancel?.isCancelled ?? false) throw MongoCancelledError();
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      hasher.close();
    } catch (_) {
      await sink.close();
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
    final actual = digestSink.value.toString();
    if (expected != null && actual != expected) {
      file.deleteSync();
      throw UpdateException(
        'The download is corrupt (checksum mismatch). Try again.',
      );
    }
    return file.path;
  }

  Future<bool> canInstall() => _installer.canInstall();
  Future<void> openInstallSettings() => _installer.openInstallSettings();
  Future<void> install(String path) => _installer.install(path);
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
