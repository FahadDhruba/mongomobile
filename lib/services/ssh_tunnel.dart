import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:mongo_wire/mongo_wire.dart';

/// Thrown when the SSH server's key differs from the one saved for it.
class HostKeyChanged implements Exception {
  HostKeyChanged(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() =>
      'The SSH server\'s host key changed (was $expected, now $actual). If '
      'the server was rebuilt, clear the saved key in the connection\'s SSH '
      'settings; otherwise someone may be intercepting the connection.';
}

/// Forwards connections through an SSH server, like `ssh -L`. One SSH
/// session carries every forwarded connection.
class SshTunnel extends ForwardingTunnel {
  SshTunnel._(this._client, this.hostKeyFingerprint);

  final SSHClient _client;

  /// `SHA256:…` of the server's host key, to save on first use.
  final String hostKeyFingerprint;

  /// Connects and signs in with a password or a private key (OpenSSH or
  /// PEM format, optionally encrypted). With [expectedFingerprint] set,
  /// a different host key fails with [HostKeyChanged].
  static Future<SshTunnel> connect({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    String? expectedFingerprint,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    List<SSHKeyPair>? identities;
    if (privateKeyPem != null && privateKeyPem.trim().isNotEmpty) {
      try {
        identities = SSHKeyPair.fromPem(
          privateKeyPem.trim(),
          passphrase == null || passphrase.isEmpty ? null : passphrase,
        );
      } on Object catch (e) {
        throw MongoConfigError(
          passphrase == null || passphrase.isEmpty
              ? 'The SSH private key could not be read; if it is encrypted, '
                    'enter its passphrase ($e)'
              : 'The SSH private key could not be read: wrong passphrase or '
                    'an unsupported format ($e)',
        );
      }
    }
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port, timeout: timeout);
    } on Object catch (e) {
      throw MongoNetworkError('Could not reach the SSH server $host:$port: $e');
    }
    String? seen;
    HostKeyChanged? changed;
    final client = SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: password == null || password.isEmpty
          ? null
          : () => password,
      onVerifyHostKey: (type, fingerprint) {
        seen = utf8.decode(fingerprint);
        if (expectedFingerprint != null &&
            expectedFingerprint.isNotEmpty &&
            expectedFingerprint != seen) {
          changed = HostKeyChanged(expectedFingerprint, seen!);
          return false;
        }
        return true;
      },
      handshakeTimeout: timeout,
      authTimeout: timeout,
    );
    try {
      await client.authenticated.timeout(timeout);
    } on Object catch (e) {
      client.close();
      if (changed != null) throw changed!;
      if (e is TimeoutException) {
        throw MongoTimeoutError('The SSH server $host:$port did not answer');
      }
      if (e is SSHAuthFailError || e is SSHAuthAbortError) {
        throw MongoAuthError(
          'The SSH server rejected the user name, password or key',
        );
      }
      throw MongoNetworkError('SSH connection to $host:$port failed: $e');
    }
    return SshTunnel._(client, seen ?? '');
  }

  @override
  Future<ForwardedStream> open(HostAddress target) async {
    try {
      final channel = await _client.forwardLocal(target.host, target.port);
      return (input: channel.stream, output: channel.sink);
    } on Object catch (e) {
      throw MongoNetworkError(
        'The SSH server could not connect to $target: $e',
      );
    }
  }

  @override
  Future<void> close() async {
    await super.close();
    _client.close();
  }
}
