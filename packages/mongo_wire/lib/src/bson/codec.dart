import 'dart:convert';
import 'dart:typed_data';

import 'types.dart';

/// Thrown when bytes are not valid BSON or a value can't be encoded.
class BsonException implements Exception {
  BsonException(this.message);
  final String message;

  @override
  String toString() => 'BsonException: $message';
}

/// Encodes and decodes BSON documents without losing type information.
abstract final class Bson {
  /// Encodes [document] (a map with string keys) as BSON.
  static Uint8List encode(Map<String, dynamic> document) {
    final w = _Writer();
    w.document(document);
    return w.takeBytes();
  }

  /// Decodes a single BSON document that fills [bytes] from [offset].
  static Map<String, dynamic> decode(Uint8List bytes, [int offset = 0]) {
    final r = _Reader(bytes, offset);
    return r.document();
  }

  /// The encoded size of [document] in bytes.
  static int sizeOf(Map<String, dynamic> document) => encode(document).length;
}

const _tDouble = 0x01;
const _tString = 0x02;
const _tDocument = 0x03;
const _tArray = 0x04;
const _tBinary = 0x05;
const _tUndefined = 0x06;
const _tObjectId = 0x07;
const _tBool = 0x08;
const _tDate = 0x09;
const _tNull = 0x0a;
const _tRegex = 0x0b;
const _tDbPointer = 0x0c;
const _tCode = 0x0d;
const _tSymbol = 0x0e;
const _tCodeWithScope = 0x0f;
const _tInt32 = 0x10;
const _tTimestamp = 0x11;
const _tInt64 = 0x12;
const _tDecimal128 = 0x13;
const _tMinKey = 0xff;
const _tMaxKey = 0x7f;

class _Writer {
  Uint8List _buf = Uint8List(256);
  late ByteData _view = ByteData.view(_buf.buffer);
  int _len = 0;

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _len);

  void _ensure(int extra) {
    if (_len + extra <= _buf.length) return;
    var size = _buf.length * 2;
    while (size < _len + extra) {
      size *= 2;
    }
    final next = Uint8List(size)..setRange(0, _len, _buf);
    _buf = next;
    _view = ByteData.view(_buf.buffer);
  }

  void _byte(int v) {
    _ensure(1);
    _buf[_len++] = v;
  }

  void _bytes(List<int> v) {
    _ensure(v.length);
    _buf.setRange(_len, _len + v.length, v);
    _len += v.length;
  }

  void _int32(int v) {
    _ensure(4);
    _view.setInt32(_len, v, Endian.little);
    _len += 4;
  }

  void _int64(int v) {
    _ensure(8);
    _view.setInt64(_len, v, Endian.little);
    _len += 8;
  }

  void _double(double v) {
    _ensure(8);
    _view.setFloat64(_len, v, Endian.little);
    _len += 8;
  }

  void _cstring(String s) {
    final b = utf8.encode(s);
    if (b.contains(0)) {
      throw BsonException('Keys and regex parts must not contain NUL: "$s"');
    }
    _bytes(b);
    _byte(0);
  }

  void _string(String s) {
    final b = utf8.encode(s);
    _int32(b.length + 1);
    _bytes(b);
    _byte(0);
  }

  void document(Map<dynamic, dynamic> doc) {
    final start = _len;
    _int32(0);
    doc.forEach((k, v) {
      if (k is! String) {
        throw BsonException('Document keys must be strings, got $k');
      }
      _element(k, v);
    });
    _byte(0);
    _view.setInt32(start, _len - start, Endian.little);
  }

  void _array(List<dynamic> list) {
    final start = _len;
    _int32(0);
    for (var i = 0; i < list.length; i++) {
      _element('$i', list[i]);
    }
    _byte(0);
    _view.setInt32(start, _len - start, Endian.little);
  }

  void _element(String key, Object? v) {
    switch (v) {
      case null:
        _byte(_tNull);
        _cstring(key);
      case double():
        _byte(_tDouble);
        _cstring(key);
        _double(v);
      case int():
        if (v >= -0x80000000 && v <= 0x7fffffff) {
          _byte(_tInt32);
          _cstring(key);
          _int32(v);
        } else {
          _byte(_tInt64);
          _cstring(key);
          _int64(v);
        }
      case BsonLong():
        _byte(_tInt64);
        _cstring(key);
        _int64(v.value);
      case String():
        _byte(_tString);
        _cstring(key);
        _string(v);
      case bool():
        _byte(_tBool);
        _cstring(key);
        _byte(v ? 1 : 0);
      case Map():
        _byte(_tDocument);
        _cstring(key);
        document(v);
      case List():
        _byte(_tArray);
        _cstring(key);
        _array(v);
      case ObjectId():
        _byte(_tObjectId);
        _cstring(key);
        _bytes(v.bytes);
      case DateTime():
        _byte(_tDate);
        _cstring(key);
        _int64(v.millisecondsSinceEpoch);
      case BsonDate():
        _byte(_tDate);
        _cstring(key);
        _int64(v.millis);
      case BsonBinary():
        _byte(_tBinary);
        _cstring(key);
        if (v.subtype == BsonBinary.binaryOld) {
          _int32(v.data.length + 4);
          _byte(v.subtype);
          _int32(v.data.length);
        } else {
          _int32(v.data.length);
          _byte(v.subtype);
        }
        _bytes(v.data);
      case Decimal128():
        _byte(_tDecimal128);
        _cstring(key);
        _bytes(v.bytes);
      case BsonTimestamp():
        _byte(_tTimestamp);
        _cstring(key);
        _ensure(8);
        _view.setUint32(_len, v.increment, Endian.little);
        _view.setUint32(_len + 4, v.seconds, Endian.little);
        _len += 8;
      case BsonRegex():
        _byte(_tRegex);
        _cstring(key);
        _cstring(v.pattern);
        _cstring(_sortedOptions(v.options));
      case BsonCode(scope: null):
        _byte(_tCode);
        _cstring(key);
        _string(v.code);
      case BsonCode():
        _byte(_tCodeWithScope);
        _cstring(key);
        final start = _len;
        _int32(0);
        _string(v.code);
        document(v.scope!);
        _view.setInt32(start, _len - start, Endian.little);
      case BsonSymbol():
        _byte(_tSymbol);
        _cstring(key);
        _string(v.value);
      case BsonDbPointer():
        _byte(_tDbPointer);
        _cstring(key);
        _string(v.namespace);
        _bytes(v.id.bytes);
      case BsonUndefined():
        _byte(_tUndefined);
        _cstring(key);
      case BsonMinKey():
        _byte(_tMinKey);
        _cstring(key);
      case BsonMaxKey():
        _byte(_tMaxKey);
        _cstring(key);
      default:
        throw BsonException(
          'Cannot encode a value of type ${v.runtimeType} at "$key"',
        );
    }
  }
}

/// The BSON spec requires regex options in alphabetical order.
String _sortedOptions(String options) => (options.split('')..sort()).join();

class _Reader {
  _Reader(this._bytes, this._pos) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _pos;

  void _need(int n) {
    if (_pos + n > _bytes.length) {
      throw BsonException('Unexpected end of BSON data at byte $_pos');
    }
  }

  int _int32() {
    _need(4);
    final v = _view.getInt32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int _uint32() {
    _need(4);
    final v = _view.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int _int64() {
    _need(8);
    final v = _view.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double _double() {
    _need(8);
    final v = _view.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  Uint8List _take(int n) {
    if (n < 0) throw BsonException('Negative length at byte $_pos');
    _need(n);
    final v = Uint8List.fromList(Uint8List.sublistView(_bytes, _pos, _pos + n));
    _pos += n;
    return v;
  }

  String _cstring() {
    final start = _pos;
    while (true) {
      _need(1);
      if (_bytes[_pos] == 0) break;
      _pos++;
    }
    final s = utf8.decode(
      Uint8List.sublistView(_bytes, start, _pos),
      allowMalformed: true,
    );
    _pos++;
    return s;
  }

  String _string() {
    final len = _int32();
    if (len < 1) throw BsonException('Invalid string length $len');
    _need(len);
    final s = utf8.decode(
      Uint8List.sublistView(_bytes, _pos, _pos + len - 1),
      allowMalformed: true,
    );
    _pos += len;
    return s;
  }

  Map<String, dynamic> document() {
    final start = _pos;
    final len = _int32();
    if (len < 5) throw BsonException('Invalid document length $len');
    final end = start + len;
    if (end > _bytes.length) {
      throw BsonException('Document length $len exceeds the available data');
    }
    final out = <String, dynamic>{};
    while (true) {
      _need(1);
      final type = _bytes[_pos++];
      if (type == 0) break;
      final key = _cstring();
      out[key] = _value(type, key);
      if (_pos > end) throw BsonException('Element overruns its document');
    }
    if (_pos != end) {
      throw BsonException('Document length mismatch at byte $_pos');
    }
    return out;
  }

  List<dynamic> _array() {
    final doc = document();
    return doc.values.toList();
  }

  Object? _value(int type, String key) {
    switch (type) {
      case _tDouble:
        return _double();
      case _tString:
        return _string();
      case _tDocument:
        return document();
      case _tArray:
        return _array();
      case _tBinary:
        var len = _int32();
        _need(1);
        final subtype = _bytes[_pos++];
        if (subtype == BsonBinary.binaryOld && len >= 4) {
          final inner = _int32();
          if (inner == len - 4) len = inner;
        }
        return BsonBinary(subtype, _take(len));
      case _tUndefined:
        return BsonUndefined.instance;
      case _tObjectId:
        return ObjectId.fromBytes(_take(12));
      case _tBool:
        _need(1);
        return _bytes[_pos++] != 0;
      case _tDate:
        return bsonDateFromMillis(_int64());
      case _tNull:
        return null;
      case _tRegex:
        final pattern = _cstring();
        return BsonRegex(pattern, _cstring());
      case _tDbPointer:
        final ns = _string();
        return BsonDbPointer(ns, ObjectId.fromBytes(_take(12)));
      case _tCode:
        return BsonCode(_string());
      case _tSymbol:
        return BsonSymbol(_string());
      case _tCodeWithScope:
        _int32();
        final code = _string();
        return BsonCode(code, document());
      case _tInt32:
        return _int32();
      case _tTimestamp:
        final inc = _uint32();
        final secs = _uint32();
        return BsonTimestamp(secs, inc);
      case _tInt64:
        return BsonLong(_int64());
      case _tDecimal128:
        return Decimal128.fromBytes(_take(16));
      case _tMinKey:
        return BsonMinKey.instance;
      case _tMaxKey:
        return BsonMaxKey.instance;
      default:
        throw BsonException(
          'Unknown BSON type 0x${type.toRadixString(16)} at "$key"',
        );
    }
  }
}
