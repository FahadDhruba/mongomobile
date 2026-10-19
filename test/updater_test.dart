import 'package:flutter_test/flutter_test.dart';
import 'package:mongomobile/services/updater.dart';

void main() {
  test('parses and compares versions', () {
    expect(parseVersion('v0.1.12'), [0, 1, 12]);
    expect(parseVersion('0.2.0'), [0, 2, 0]);
    expect(parseVersion('dev'), isNull);
    expect(parseVersion('v1.2'), isNull);
    expect(compareVersions([0, 1, 10], [0, 1, 9]), greaterThan(0));
    expect(compareVersions([0, 2, 0], [0, 1, 99]), greaterThan(0));
    expect(compareVersions([0, 1, 5], [0, 1, 5]), 0);
  });

  test('reads a GitHub release with its APK and checksum', () {
    final r = ReleaseInfo.fromGitHub({
      'tag_name': 'v0.1.7',
      'html_url': 'https://github.com/FahadDhruba/mongomobile/releases/tag/v0.1.7',
      'body': 'Notes',
      'assets': [
        {
          'name': 'mongomobile-0.1.7.apk.sha256',
          'browser_download_url': 'https://example.com/a.apk.sha256',
          'size': 93,
        },
        {
          'name': 'mongomobile-0.1.7.apk',
          'browser_download_url': 'https://example.com/a.apk',
          'size': 57000000,
        },
      ],
    })!;
    expect(r.versionName, '0.1.7');
    expect(r.apkUrl, 'https://example.com/a.apk');
    expect(r.sha256Url, 'https://example.com/a.apk.sha256');
    expect(r.apkSize, 57000000);
    expect(r.notes, 'Notes');
  });

  test('ignores releases without an APK or a version tag', () {
    expect(ReleaseInfo.fromGitHub({'tag_name': 'v0.1.7', 'assets': []}), isNull);
    expect(
        ReleaseInfo.fromGitHub({
          'tag_name': 'nightly',
          'assets': [
            {'name': 'x.apk', 'browser_download_url': 'u'}
          ]
        }),
        isNull);
  });

  test('development builds never offer updates', () {
    expect(Updater(currentVersion: 'dev').current, isNull);
    expect(Updater(currentVersion: '0.1.6').current, [0, 1, 6]);
  });
}
