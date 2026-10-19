/// BSON values are represented with plain Dart types where that is lossless
/// and with the small classes in this file where it is not.
///
/// | BSON type        | Dart value                         |
/// |------------------|------------------------------------|
/// | double           | [double]                           |
/// | string           | [String]                           |
/// | document         | `Map<String, dynamic>` (ordered)   |
/// | array            | `List<dynamic>`                    |
/// | binary           | [BsonBinary]                       |
/// | undefined        | [BsonUndefined]                    |
/// | ObjectId         | [ObjectId]                         |
/// | bool             | [bool]                             |
/// | date             | [DateTime] (UTC) or [BsonDate]     |
/// | null             | `null`                             |
/// | regex            | [BsonRegex]                        |
/// | DBPointer        | [BsonDbPointer]                    |
/// | JavaScript code  | [BsonCode]                         |
/// | symbol           | [BsonSymbol]                       |
/// | int32            | [int]                              |
/// | timestamp        | [BsonTimestamp]                    |
/// | int64            | [BsonLong]                         |
/// | decimal128       | [Decimal128]                       |
/// | min / max key    | [BsonMinKey] / [BsonMaxKey]        |
///
/// Encoding a Dart [int] produces an int32 when it fits and an int64
/// otherwise. Decoding an int64 always produces a [BsonLong], so documents
/// keep their types when they are read and written back.
library;

import 'dart:math';
import 'dart:typed_data';

import 'decimal128.dart';

export 'decimal128.dart';

/// A 12-byte MongoDB ObjectId.
final class ObjectId implements Comparable<ObjectId> {
  ObjectId.fromBytes(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length != 12) {
      throw ArgumentError('An ObjectId has 12 bytes, got ${bytes.length}');
    }
  }

  /// Generates a new ObjectId the same way drivers do: 4 bytes of seconds
  /// since the epoch, 5 random bytes per process and a 3-byte counter.
  factory ObjectId() {
    final b = Uint8List(12);
    final secs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    b[0] = (secs >> 24) & 0xff;
    b[1] = (secs >> 16) & 0xff;
    b[2] = (secs >> 8) & 0xff;
    b[3] = secs & 0xff;
    b.setRange(4, 9, _processUnique);
    final c = _counter = (_counter + 1) & 0xffffff;
    b[9] = (c >> 16) & 0xff;
    b[10] = (c >> 8) & 0xff;
    b[11] = c & 0xff;
    return ObjectId.fromBytes(b);
  }

  factory ObjectId.parse(String hex) {
    if (!isValidHex(hex)) {
      throw FormatException('Invalid ObjectId hex string', hex);
    }
    final b = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      b[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return ObjectId.fromBytes(b);
  }

  static bool isValidHex(String s) =>
      s.length == 24 && RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(s);

  static final Random _random = Random.secure();
  static final List<int> _processUnique =
      List<int>.generate(5, (_) => _random.nextInt(256));
  static int _counter = _random.nextInt(0xffffff);

  final Uint8List bytes;

  String get hex {
    final sb = StringBuffer();
    for (final v in bytes) {
      sb.write(v.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// The creation time encoded in the first four bytes.
  DateTime get timestamp {
    final secs =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
  }

  @override
  int compareTo(ObjectId other) {
    for (var i = 0; i < 12; i++) {
      final d = bytes[i] - other.bytes[i];
      if (d != 0) return d;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) => other is ObjectId && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'ObjectId("$hex")';
}

/// A BSON int64. Dart ints are 64-bit on the VM, so the value is exact.
final class BsonLong implements Comparable<BsonLong> {
  const BsonLong(this.value);
  final int value;

  @override
  int compareTo(BsonLong other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is BsonLong && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'NumberLong($value)';
}

/// A BSON date outside the range a Dart [DateTime] can hold.
final class BsonDate {
  const BsonDate(this.millis);
  final int millis;

  @override
  bool operator ==(Object other) => other is BsonDate && other.millis == millis;

  @override
  int get hashCode => millis.hashCode;

  @override
  String toString() => 'Date($millis)';
}

/// BSON binary data with its subtype.
final class BsonBinary {
  BsonBinary(this.subtype, List<int> data) : data = Uint8List.fromList(data);

  static const generic = 0x00;
  static const function = 0x01;
  static const binaryOld = 0x02;
  static const uuidOld = 0x03;
  static const uuid = 0x04;
  static const md5 = 0x05;
  static const encrypted = 0x06;
  static const column = 0x07;
  static const sensitive = 0x08;
  static const vector = 0x09;

  /// Parses a UUID string such as `123e4567-e89b-12d3-a456-426614174000`
  /// into subtype 4 binary data.
  factory BsonBinary.uuidFromString(String s) {
    final hex = s.replaceAll('-', '');
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
      throw FormatException('Invalid UUID', s);
    }
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return BsonBinary(uuid, b);
  }

  final int subtype;
  final Uint8List data;

  bool get isUuid => subtype == uuid && data.length == 16;

  String get hex {
    final sb = StringBuffer();
    for (final v in data) {
      sb.write(v.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// The canonical UUID string, for subtype 4 values of 16 bytes.
  String get uuidString {
    final h = hex;
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  bool operator ==(Object other) =>
      other is BsonBinary &&
      other.subtype == subtype &&
      _bytesEqual(other.data, data);

  @override
  int get hashCode => Object.hash(subtype, Object.hashAll(data));

  @override
  String toString() => 'Binary($subtype, ${data.length} bytes)';
}

/// A BSON regular expression. [options] is kept exactly as stored.
final class BsonRegex {
  const BsonRegex(this.pattern, [this.options = '']);
  final String pattern;
  final String options;

  @override
  bool operator ==(Object other) =>
      other is BsonRegex && other.pattern == pattern && other.options == options;

  @override
  int get hashCode => Object.hash(pattern, options);

  @override
  String toString() => '/$pattern/$options';
}

/// JavaScript code, optionally with a scope document.
final class BsonCode {
  const BsonCode(this.code, [this.scope]);
  final String code;
  final Map<String, dynamic>? scope;

  @override
  bool operator ==(Object other) =>
      other is BsonCode && other.code == code && other.scope == scope;

  @override
  int get hashCode => Object.hash(code, scope);

  @override
  String toString() => 'Code($code)';
}

/// The deprecated BSON symbol type.
final class BsonSymbol {
  const BsonSymbol(this.value);
  final String value;

  @override
  bool operator ==(Object other) => other is BsonSymbol && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Symbol($value)';
}

/// The deprecated BSON DBPointer type.
final class BsonDbPointer {
  const BsonDbPointer(this.namespace, this.id);
  final String namespace;
  final ObjectId id;

  @override
  bool operator ==(Object other) =>
      other is BsonDbPointer && other.namespace == namespace && other.id == id;

  @override
  int get hashCode => Object.hash(namespace, id);

  @override
  String toString() => 'DBPointer($namespace, $id)';
}

/// A BSON timestamp: seconds since the epoch and an increment.
final class BsonTimestamp implements Comparable<BsonTimestamp> {
  const BsonTimestamp(this.seconds, this.increment);
  final int seconds;
  final int increment;

  @override
  int compareTo(BsonTimestamp other) {
    final c = seconds.compareTo(other.seconds);
    return c != 0 ? c : increment.compareTo(other.increment);
  }

  @override
  bool operator ==(Object other) =>
      other is BsonTimestamp &&
      other.seconds == seconds &&
      other.increment == increment;

  @override
  int get hashCode => Object.hash(seconds, increment);

  @override
  String toString() => 'Timestamp($seconds, $increment)';
}

/// The deprecated BSON undefined value.
final class BsonUndefined {
  const BsonUndefined._();
  static const instance = BsonUndefined._();

  @override
  String toString() => 'undefined';
}

final class BsonMinKey {
  const BsonMinKey._();
  static const instance = BsonMinKey._();

  @override
  String toString() => 'MinKey';
}

final class BsonMaxKey {
  const BsonMaxKey._();
  static const instance = BsonMaxKey._();

  @override
  String toString() => 'MaxKey';
}

/// The largest absolute millisecond value a [DateTime] accepts.
const int maxDateTimeMillis = 8640000000000000;

/// Converts a BSON date in milliseconds into the Dart value used for it.
Object bsonDateFromMillis(int millis) => millis.abs() <= maxDateTimeMillis
    ? DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true)
    : BsonDate(millis);

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Short type name used in the UI and error messages.
String bsonTypeName(Object? v) => switch (v) {
      null => 'Null',
      String() => 'String',
      bool() => 'Boolean',
      int() => 'Int32',
      double() => 'Double',
      BsonLong() => 'Int64',
      Decimal128() => 'Decimal128',
      ObjectId() => 'ObjectId',
      DateTime() || BsonDate() => 'Date',
      Map() => 'Object',
      List() => 'Array',
      BsonBinary(isUuid: true) => 'UUID',
      BsonBinary() => 'Binary',
      BsonRegex() => 'BSONRegExp',
      BsonTimestamp() => 'Timestamp',
      BsonCode() => 'Code',
      BsonSymbol() => 'Symbol',
      BsonDbPointer() => 'DBPointer',
      BsonUndefined() => 'Undefined',
      BsonMinKey() => 'MinKey',
      BsonMaxKey() => 'MaxKey',
      _ => v.runtimeType.toString(),
    };
