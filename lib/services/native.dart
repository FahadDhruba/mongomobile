import 'package:flutter/services.dart';

import 'exporter.dart';

/// Saving files through Android's "Save to" picker (Storage Access
/// Framework), implemented in MainActivity. No storage permission needed.
class NativeFiles {
  static const _channel = MethodChannel('com.mongomobile.app/files');

  /// Asks the user where to save [name]. Returns null when they cancel.
  Future<ExportSink?> create(String name, String mimeType) async {
    final id = await _channel.invokeMethod<int>('createDocument', {
      'name': name,
      'mimeType': mimeType,
    });
    return id == null ? null : _DocumentSink(id);
  }
}

class _DocumentSink implements ExportSink {
  _DocumentSink(this.id);
  final int id;

  static const _channel = NativeFiles._channel;

  @override
  Future<void> add(List<int> bytes) => _channel.invokeMethod<void>('write', {
    'id': id,
    'bytes': Uint8List.fromList(bytes),
  });

  @override
  Future<void> close() => _channel.invokeMethod<void>('close', {'id': id});

  @override
  Future<void> abort() async {
    try {
      await _channel.invokeMethod<void>('abort', {'id': id});
    } on PlatformException {
      // Best effort: the partial file may stay behind.
    }
  }
}

/// Installing a downloaded update, implemented in MainActivity.
class NativeInstaller {
  static const _channel = MethodChannel('com.mongomobile.app/updater');

  /// The app's private cache directory.
  Future<String> cacheDir() async =>
      (await _channel.invokeMethod<String>('cacheDir'))!;

  /// Whether the user allowed this app to install packages.
  Future<bool> canInstall() async =>
      (await _channel.invokeMethod<bool>('canInstall')) ?? false;

  /// Opens the system screen where the user can allow installs.
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  /// Hands the APK at [path] to the system installer.
  Future<void> install(String path) =>
      _channel.invokeMethod<void>('install', {'path': path});
}
