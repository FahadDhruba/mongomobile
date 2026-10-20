import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bson/codec.dart';
import '../bson/types.dart';
import '../client.dart';
import '../errors.dart';
import '../wire/aws.dart';
import 'aead.dart';

/// Master keys for the data keys in the key vault.
final class KmsProviders {
  const KmsProviders({this.localKey, this.aws});

  /// The 96-byte "local" master key.
  final Uint8List? localKey;

  /// Credentials for keys kept in AWS KMS.
  final AwsCredentials? aws;

  bool get isEmpty => localKey == null && aws == null;
}

/// A field that was encrypted, so it can be encrypted again on save.
final class EncryptedField {
  const EncryptedField(this.path, this.keyId, this.deterministic);

  /// Field names and array indexes from the document root.
  final List<Object> path;
  final BsonBinary keyId;
  final bool deterministic;
}

/// A document with its encrypted fields decrypted.
final class DecryptedDocument {
  const DecryptedDocument(this.document, this.fields, this.failures);
  final Map<String, dynamic> document;
  final List<EncryptedField> fields;

  /// Encrypted values that could not be decrypted (no key, wrong master
  /// key), by path; they stay encrypted in [document].
  final Map<String, String> failures;
}

/// Whether [v] is a client-side encrypted value (BSON binary subtype 6).
bool isEncryptedValue(Object? v) =>
    v is BsonBinary && v.subtype == 6 && v.data.isNotEmpty;

/// Client-side field level encryption (CSFLE, "FLE1") for values read and
/// written by the app: decrypts deterministic and random values with data
/// keys from the key vault, whose key material is protected by a local or
/// AWS KMS master key, and encrypts them again on save.
///
/// Queryable Encryption values are recognised but not decrypted.
class FieldEncryption {
  FieldEncryption({
    required this.client,
    required this.keyVault,
    required this.kms,
    HttpClient? http,
  }) : _http = http ?? HttpClient();

  final MongoClient client;
  final Namespace keyVault;
  final KmsProviders kms;
  final HttpClient _http;
  final _keys = <String, Future<Aead>>{};

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// The data key [id], fetched and unwrapped once. A failure is not
  /// cached, so fixing the settings and retrying works.
  Future<Aead> _key(Uint8List id) {
    final hex = _hex(id);
    final cached = _keys[hex];
    if (cached != null) return cached;
    final loading = _keys[hex] = _loadKey(id);
    loading.then(
      (_) {},
      onError: (Object _) {
        _keys.remove(hex);
      },
    );
    return loading;
  }

  Future<Aead> _loadKey(Uint8List id) async {
    final r = await client.find(
      keyVault,
      FindRequest(
        filter: {'_id': BsonBinary(4, id)},
        limit: 1,
        maxTime: const Duration(seconds: 20),
      ),
    );
    if (r.documents.isEmpty) {
      throw MongoConfigError(
        'Data key ${_uuid(id)} is not in the key vault $keyVault',
      );
    }
    final doc = r.documents.single;
    final material = doc['keyMaterial'];
    final master = doc['masterKey'];
    if (material is! BsonBinary || master is! Map) {
      throw MongoConfigError('Data key ${_uuid(id)} is malformed');
    }
    final plain = switch (master['provider']) {
      'local' => _local(material.data),
      'aws' => await _aws(material.data, master),
      final p => throw MongoConfigError(
        'Data key ${_uuid(id)} uses the "$p" KMS, which the app does not '
        'support (local and AWS are)',
      ),
    };
    return Aead(Uint8List.fromList(plain));
  }

  static String _uuid(List<int> b) {
    final h = _hex(b);
    if (h.length != 32) return h;
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  List<int> _local(List<int> material) {
    final key = kms.localKey;
    if (key == null) {
      throw MongoConfigError(
        'A data key uses the local master key; add it in the connection\'s '
        'encryption settings',
      );
    }
    try {
      return Aead(key).decrypt(material, const []);
    } on MongoAuthError {
      throw MongoAuthError('The local master key does not open the data key');
    }
  }

  Future<List<int>> _aws(
    List<int> material,
    Map<dynamic, dynamic> master,
  ) async {
    final creds = kms.aws;
    if (creds == null) {
      throw MongoConfigError(
        'A data key is kept in AWS KMS; add AWS credentials in the '
        'connection\'s encryption settings',
      );
    }
    final region = '${master['region'] ?? ''}';
    final endpoint = master['endpoint'] as String?;
    final host = endpoint == null || endpoint.isEmpty
        ? 'kms.$region.amazonaws.com'
        : endpoint.split(':').first;
    final body = jsonEncode({'CiphertextBlob': base64.encode(material)});
    final date = amzDate(DateTime.now());
    final headers = {
      'Content-Type': 'application/x-amz-json-1.1',
      'Host': host,
      'X-Amz-Date': date,
      'X-Amz-Target': 'TrentService.Decrypt',
      if (creds.sessionToken != null)
        'X-Amz-Security-Token': creds.sessionToken!,
    };
    final auth = sigV4Authorization(
      method: 'POST',
      path: '/',
      headers: headers,
      body: body,
      region: region,
      service: 'kms',
      credentials: creds,
    );
    final req = await _http.postUrl(Uri.parse('https://$host/'));
    headers.forEach(req.headers.set);
    req.headers.set('Authorization', auth);
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw MongoAuthError(
        'AWS KMS refused to decrypt the data key (${res.statusCode}): $text',
      );
    }
    final j = jsonDecode(text) as Map;
    return base64.decode(j['Plaintext'] as String);
  }

  /// The BSON type byte and bytes of a single value.
  static (int, Uint8List) _valueBytes(Object? v) {
    final doc = Bson.encode({'v': v});
    // int32 length, type, "v", 0, value…, 0
    return (doc[4], Uint8List.sublistView(doc, 7, doc.length - 1));
  }

  static Object? _fromValueBytes(int type, List<int> bytes) {
    final b = BytesBuilder()
      ..add([0, 0, 0, 0, type, 0x76, 0])
      ..add(bytes)
      ..addByte(0);
    final doc = b.toBytes();
    ByteData.sublistView(doc).setInt32(0, doc.length, Endian.little);
    return Bson.decode(doc)['v'];
  }

  /// Decrypts one CSFLE value.
  Future<Object?> decryptValue(BsonBinary blob) async {
    final d = blob.data;
    if (d.isEmpty || (d[0] != 1 && d[0] != 2)) {
      throw MongoConfigError(
        d.isNotEmpty && d[0] >= 6
            ? 'This value uses Queryable Encryption, which the app shows '
                  'but does not decrypt'
            : 'Unknown encrypted value format ${d.isEmpty ? '' : d[0]}',
      );
    }
    if (d.length < 18) {
      throw MongoConfigError('The encrypted value is too short');
    }
    final keyId = Uint8List.sublistView(d, 1, 17);
    final type = d[17];
    final aead = await _key(keyId);
    final plain = aead.decrypt(d.sublist(18), d.sublist(0, 18));
    return _fromValueBytes(type, plain);
  }

  /// Encrypts [value] with the data key [keyId].
  Future<BsonBinary> encryptValue(
    Object? value,
    BsonBinary keyId, {
    required bool deterministic,
  }) async {
    final (type, bytes) = _valueBytes(value);
    final ad = [deterministic ? 1 : 2, ...keyId.data, type];
    final aead = await _key(Uint8List.fromList(keyId.data));
    final c = aead.encrypt(bytes, ad, deterministic: deterministic);
    return BsonBinary(6, [...ad, ...c]);
  }

  /// Decrypts every CSFLE value in [doc], remembering where they were.
  Future<DecryptedDocument> decryptDocument(Map<String, dynamic> doc) async {
    final fields = <EncryptedField>[];
    final failures = <String, String>{};
    Future<Object?> walk(Object? v, List<Object> path) async {
      if (isEncryptedValue(v)) {
        final blob = v as BsonBinary;
        final kind = blob.data[0];
        if (kind != 1 && kind != 2) return v;
        try {
          final plain = await decryptValue(blob);
          fields.add(
            EncryptedField(
              path,
              BsonBinary(4, blob.data.sublist(1, 17)),
              kind == 1,
            ),
          );
          return plain;
        } on MongoException catch (e) {
          failures[path.join('.')] = e.message;
          return v;
        }
      }
      if (v is Map) {
        return <String, dynamic>{
          for (final e in v.entries)
            '${e.key}': await walk(e.value, [...path, '${e.key}']),
        };
      }
      if (v is List) {
        return [
          for (var i = 0; i < v.length; i++) await walk(v[i], [...path, i]),
        ];
      }
      return v;
    }

    final out = await walk(doc, const []) as Map<String, dynamic>;
    return DecryptedDocument(out, fields, failures);
  }

  /// Encrypts the [fields] of [doc] again, where they still exist, so a
  /// decrypted document can be saved without writing plain text.
  Future<Map<String, dynamic>> reencrypt(
    Map<String, dynamic> doc,
    List<EncryptedField> fields,
  ) async {
    Object? copy(Object? v) => switch (v) {
      Map() => <String, dynamic>{
        for (final e in v.entries) '${e.key}': copy(e.value),
      },
      List() => [for (final e in v) copy(e)],
      _ => v,
    };
    final out = copy(doc) as Map<String, dynamic>;
    for (final f in fields) {
      Object? parent = out;
      for (final p in f.path.take(f.path.length - 1)) {
        parent = switch ((parent, p)) {
          (final Map<dynamic, dynamic> m, final String k) => m[k],
          (final List<dynamic> l, final int i) when i < l.length => l[i],
          _ => null,
        };
      }
      final last = f.path.last;
      switch ((parent, last)) {
        case (final Map<dynamic, dynamic> m, final String k)
            when m.containsKey(k):
          if (!isEncryptedValue(m[k])) {
            m[k] = await encryptValue(
              m[k],
              f.keyId,
              deterministic: f.deterministic,
            );
          }
        case (final List<dynamic> l, final int i) when i < l.length:
          if (!isEncryptedValue(l[i])) {
            l[i] = await encryptValue(
              l[i],
              f.keyId,
              deterministic: f.deterministic,
            );
          }
        default:
          break;
      }
    }
    return out;
  }
}
