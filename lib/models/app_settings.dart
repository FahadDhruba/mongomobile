import 'package:flutter/material.dart';

/// User preferences, stored in shared preferences.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.queryTimeoutMs = 10000,
    this.countTimeoutMs = 5000,
    this.defaultPageSize = 25,
    this.maxPageMegabytes = 4,
    this.biometricLock = false,
    this.stringPreviewLength = 200,
    this.autoCheckUpdates = true,
  });

  static const pageSizes = [10, 25, 50, 100];

  final ThemeMode themeMode;

  /// maxTimeMS sent with every query.
  final int queryTimeoutMs;

  /// maxTimeMS for the background count of filtered queries.
  final int countTimeoutMs;
  final int defaultPageSize;

  /// Soft cap on the bytes read for one page.
  final int maxPageMegabytes;
  final bool biometricLock;

  /// Strings longer than this are cut with a "show more" control.
  final int stringPreviewLength;

  /// Look for a newer release on GitHub when the app starts.
  final bool autoCheckUpdates;

  Duration get queryTimeout => Duration(milliseconds: queryTimeoutMs);
  Duration get countTimeout => Duration(milliseconds: countTimeoutMs);
  int get maxPageBytes => maxPageMegabytes * 1024 * 1024;

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? queryTimeoutMs,
    int? countTimeoutMs,
    int? defaultPageSize,
    int? maxPageMegabytes,
    bool? biometricLock,
    int? stringPreviewLength,
    bool? autoCheckUpdates,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    queryTimeoutMs: queryTimeoutMs ?? this.queryTimeoutMs,
    countTimeoutMs: countTimeoutMs ?? this.countTimeoutMs,
    defaultPageSize: defaultPageSize ?? this.defaultPageSize,
    maxPageMegabytes: maxPageMegabytes ?? this.maxPageMegabytes,
    biometricLock: biometricLock ?? this.biometricLock,
    stringPreviewLength: stringPreviewLength ?? this.stringPreviewLength,
    autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
  );

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.name,
    'queryTimeoutMs': queryTimeoutMs,
    'countTimeoutMs': countTimeoutMs,
    'defaultPageSize': defaultPageSize,
    'maxPageMegabytes': maxPageMegabytes,
    'biometricLock': biometricLock,
    'stringPreviewLength': stringPreviewLength,
    'autoCheckUpdates': autoCheckUpdates,
  };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    const d = AppSettings();
    int read(String k, int fallback, int min, int max) {
      final v = j[k];
      return v is int && v >= min && v <= max ? v : fallback;
    }

    final pageSize = read('defaultPageSize', d.defaultPageSize, 1, 100);
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == j['themeMode'],
        orElse: () => d.themeMode,
      ),
      queryTimeoutMs: read('queryTimeoutMs', d.queryTimeoutMs, 500, 600000),
      countTimeoutMs: read('countTimeoutMs', d.countTimeoutMs, 500, 600000),
      defaultPageSize: pageSizes.contains(pageSize)
          ? pageSize
          : d.defaultPageSize,
      maxPageMegabytes: read('maxPageMegabytes', d.maxPageMegabytes, 1, 32),
      biometricLock: j['biometricLock'] == true,
      stringPreviewLength: read(
        'stringPreviewLength',
        d.stringPreviewLength,
        40,
        100000,
      ),
      autoCheckUpdates: j['autoCheckUpdates'] != false,
    );
  }
}
