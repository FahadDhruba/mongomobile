import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../bson/types.dart';

/// A parse error with the position it was found at.
class EJsonParseException implements FormatException {
  EJsonParseException(this.message, this.source, this.offset);

  @override
  final String message;
  @override
  final String source;
  @override
  final int offset;

  /// 1-based line of [offset].
  int get line => '\n'.allMatches(source.substring(0, offset)).length + 1;

  /// 1-based column of [offset].
  int get column =>
      offset - (source.lastIndexOf('\n', max(0, offset - 1)) + 1) + 1;

  @override
  String toString() => '$message (line $line, column $column)';
}

/// Parses Extended JSON and the shell syntax people paste from mongosh or
/// Compass into Dart BSON values.
///
/// Besides strict JSON this accepts unquoted and single-quoted keys,
/// single-quoted strings, trailing commas, comments, `/regex/flags`,
/// `undefined`, `NaN`, `Infinity`, and constructors such as `ObjectId(...)`,
/// `ISODate(...)`, `new Date(...)`, `NumberLong(...)`, `NumberInt(...)`,
/// `NumberDecimal(...)`, `UUID(...)`, `BinData(...)`, `Timestamp(...)`,
/// `MinKey()` and `MaxKey()`. Extended JSON wrappers like `{"$oid": ...}`
/// are converted to their BSON types.
///
/// Integer literals become Int32 when they fit and Int64 otherwise; literals
/// with a fraction or exponent become doubles.
class EJsonParser {
  EJsonParser(this.source);

  final String source;
  int _pos = 0;

  /// Parses a document. An empty or blank input gives an empty document
  /// when [allowEmpty] is true.
  static Map<String, dynamic> parseDocument(
    String source, {
    bool allowEmpty = false,
  }) {
    if (allowEmpty && source.trim().isEmpty) return <String, dynamic>{};
    final p = EJsonParser(source);
    final v = p.parseValue();
    if (v is! Map<String, dynamic>) {
      throw EJsonParseException('Expected a document like { ... }', source, 0);
    }
    return v;
  }

  /// Parses a JSON array of documents, or a single document.
  static List<Map<String, dynamic>> parseDocuments(String source) {
    final v = EJsonParser(source).parseValue();
    if (v is Map<String, dynamic>) return [v];
    if (v is List && v.every((e) => e is Map<String, dynamic>)) {
      return v.cast<Map<String, dynamic>>();
    }
    throw EJsonParseException(
      'Expected a document or an array of documents',
      source,
      0,
    );
  }

  /// Parses one complete value; trailing text other than whitespace and
  /// comments is an error.
  Object? parseValue() {
    _skip();
    final v = _value();
    _skip();
    if (_pos < source.length) _fail('Unexpected text after the value');
    return v;
  }

  Never _fail(String message, [int? at]) =>
      throw EJsonParseException(message, source, at ?? _pos);

  bool get _done => _pos >= source.length;
  String get _ch => source[_pos];

  void _skip() {
    while (!_done) {
      final c = _ch;
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == ' ') {
        _pos++;
      } else if (source.startsWith('//', _pos)) {
        final nl = source.indexOf('\n', _pos);
        _pos = nl < 0 ? source.length : nl + 1;
      } else if (source.startsWith('/*', _pos)) {
        final end = source.indexOf('*/', _pos + 2);
        if (end < 0) _fail('Unterminated comment');
        _pos = end + 2;
      } else {
        break;
      }
    }
  }

  void _expect(String c) {
    _skip();
    if (_done || _ch != c) _fail('Expected "$c"');
    _pos++;
  }

  Object? _value() {
    _skip();
    if (_done) _fail('Unexpected end of input');
    final c = _ch;
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == '"' || c == "'") return _string();
    if (c == '/') return _regexLiteral();
    if (c == '-' || c == '+' || c == '.' || _isDigit(c)) return _number();
    if (_isIdentStart(c)) return _identifierValue();
    _fail('Unexpected character "$c"');
  }

  Object _object() {
    final start = _pos;
    _pos++;
    final map = <String, dynamic>{};
    _skip();
    while (true) {
      _skip();
      if (_done) _fail('Unterminated object', start);
      if (_ch == '}') {
        _pos++;
        break;
      }
      final key = _key();
      _expect(':');
      map[key] = _value();
      _skip();
      if (_done) _fail('Unterminated object', start);
      if (_ch == ',') {
        _pos++;
        continue;
      }
      if (_ch == '}') {
        _pos++;
        break;
      }
      _fail('Expected "," or "}"');
    }
    return _convertWrapper(map, start);
  }

  String _key() {
    _skip();
    final c = _ch;
    if (c == '"' || c == "'") return _string();
    if (_isIdentStart(c) || _isDigit(c)) {
      final start = _pos;
      while (!_done && (_isIdentPart(_ch) || _ch == '.')) {
        _pos++;
      }
      return source.substring(start, _pos);
    }
    _fail('Expected a field name');
  }

  List<dynamic> _array() {
    final start = _pos;
    _pos++;
    final list = <dynamic>[];
    while (true) {
      _skip();
      if (_done) _fail('Unterminated array', start);
      if (_ch == ']') {
        _pos++;
        break;
      }
      list.add(_value());
      _skip();
      if (_done) _fail('Unterminated array', start);
      if (_ch == ',') {
        _pos++;
        continue;
      }
      if (_ch == ']') {
        _pos++;
        break;
      }
      _fail('Expected "," or "]"');
    }
    return list;
  }

  String _string() {
    final quote = _ch;
    final start = _pos;
    _pos++;
    final sb = StringBuffer();
    while (true) {
      if (_done) _fail('Unterminated string', start);
      final c = _ch;
      if (c == quote) {
        _pos++;
        break;
      }
      if (c == '\\') {
        _pos++;
        if (_done) _fail('Unterminated string', start);
        final e = _ch;
        _pos++;
        switch (e) {
          case 'n':
            sb.write('\n');
          case 't':
            sb.write('\t');
          case 'r':
            sb.write('\r');
          case 'b':
            sb.write('\b');
          case 'f':
            sb.write('\f');
          case '0':
            sb.write('\u0000');
          case 'u':
            if (_pos + 4 > source.length) _fail('Invalid \\u escape');
            final code = int.tryParse(
              source.substring(_pos, _pos + 4),
              radix: 16,
            );
            if (code == null) _fail('Invalid \\u escape');
            sb.writeCharCode(code);
            _pos += 4;
          case '\n':
            break;
          default:
            sb.write(e);
        }
        continue;
      }
      if (c == '\n' && quote == "'") _fail('Unterminated string', start);
      sb.write(c);
      _pos++;
    }
    return sb.toString();
  }

  BsonRegex _regexLiteral() {
    final start = _pos;
    _pos++;
    final sb = StringBuffer();
    var inClass = false;
    while (true) {
      if (_done || _ch == '\n') _fail('Unterminated regular expression', start);
      final c = _ch;
      if (c == '\\') {
        sb.write(c);
        _pos++;
        if (_done) _fail('Unterminated regular expression', start);
        sb.write(_ch);
        _pos++;
        continue;
      }
      if (c == '[') inClass = true;
      if (c == ']') inClass = false;
      if (c == '/' && !inClass) {
        _pos++;
        break;
      }
      sb.write(c);
      _pos++;
    }
    final fStart = _pos;
    while (!_done && RegExp('[a-z]').hasMatch(_ch)) {
      _pos++;
    }
    final flags = source.substring(fStart, _pos);
    _checkRegexFlags(flags, fStart);
    return BsonRegex(sb.toString(), _sorted(flags));
  }

  void _checkRegexFlags(String flags, int at) {
    for (final f in flags.split('')) {
      if (!'imsxlu'.contains(f)) _fail('Unsupported regex flag "$f"', at);
    }
  }

  Object _number() {
    final start = _pos;
    if (_ch == '-' || _ch == '+') _pos++;
    if (source.startsWith('Infinity', _pos)) {
      _pos += 8;
      return source[start] == '-' ? double.negativeInfinity : double.infinity;
    }
    var isDouble = false;
    if (source.startsWith('0x', _pos) || source.startsWith('0X', _pos)) {
      _pos += 2;
      final hs = _pos;
      while (!_done && RegExp('[0-9a-fA-F]').hasMatch(_ch)) {
        _pos++;
      }
      final v = int.tryParse(source.substring(hs, _pos), radix: 16);
      if (v == null) _fail('Invalid hex number', start);
      return source[start] == '-' ? -v : v;
    }
    while (!_done && _isDigit(_ch)) {
      _pos++;
    }
    if (!_done && _ch == '.') {
      isDouble = true;
      _pos++;
      while (!_done && _isDigit(_ch)) {
        _pos++;
      }
    }
    if (!_done && (_ch == 'e' || _ch == 'E')) {
      isDouble = true;
      _pos++;
      if (!_done && (_ch == '+' || _ch == '-')) _pos++;
      final es = _pos;
      while (!_done && _isDigit(_ch)) {
        _pos++;
      }
      if (_pos == es) _fail('Invalid number', start);
    }
    var text = source.substring(start, _pos);
    if (text.startsWith('+')) text = text.substring(1);
    if (text == '-' || text.isEmpty || text == '.' || text == '-.') {
      _fail('Invalid number', start);
    }
    if (isDouble) {
      final d = double.tryParse(text);
      if (d == null) _fail('Invalid number', start);
      return d;
    }
    final i = int.tryParse(text);
    if (i != null) return i;
    final d = double.tryParse(text);
    if (d == null) _fail('Invalid number', start);
    return d;
  }

  String _identifier() {
    final start = _pos;
    while (!_done && _isIdentPart(_ch)) {
      _pos++;
    }
    return source.substring(start, _pos);
  }

  Object? _identifierValue() {
    final start = _pos;
    var name = _identifier();
    if (name == 'new') {
      _skip();
      name = _identifier();
      if (name.isEmpty) _fail('Expected a constructor after "new"');
    }
    _skip();
    final isCall = !_done && _ch == '(';
    if (!isCall) {
      switch (name) {
        case 'true':
          return true;
        case 'false':
          return false;
        case 'null':
          return null;
        case 'undefined':
          return BsonUndefined.instance;
        case 'NaN':
          return double.nan;
        case 'Infinity':
          return double.infinity;
        case 'MinKey':
          return BsonMinKey.instance;
        case 'MaxKey':
          return BsonMaxKey.instance;
      }
      _fail('Unknown value "$name"', start);
    }
    final args = _args();
    return _construct(name, args, start);
  }

  List<Object?> _args() {
    _pos++; // (
    final args = <Object?>[];
    while (true) {
      _skip();
      if (_done) _fail('Unterminated argument list');
      if (_ch == ')') {
        _pos++;
        break;
      }
      args.add(_value());
      _skip();
      if (!_done && _ch == ',') {
        _pos++;
        continue;
      }
      if (!_done && _ch == ')') {
        _pos++;
        break;
      }
      _fail('Expected "," or ")"');
    }
    return args;
  }

  Object? _construct(String name, List<Object?> args, int at) {
    String str(int i, String what) {
      if (args.length <= i) _fail('$name() needs $what', at);
      final v = args[i];
      if (v is String) return v;
      if (v is num) return _numText(v);
      if (v is BsonLong) return '${v.value}';
      _fail('$name() expects $what', at);
    }

    try {
      switch (name) {
        case 'ObjectId':
        case 'ObjectID':
          if (args.isEmpty) return ObjectId();
          return ObjectId.parse(str(0, 'a 24-character hex string'));
        case 'ISODate':
        case 'Date':
          if (args.isEmpty) return DateTime.now().toUtc();
          final a = args[0];
          if (a is int) return bsonDateFromMillis(a);
          if (a is double) return bsonDateFromMillis(a.toInt());
          if (a is BsonLong) return bsonDateFromMillis(a.value);
          return parseIsoDate(str(0, 'a date string'));
        case 'NumberInt':
        case 'Int32':
          final s = str(0, 'a number');
          final v = int.tryParse(s) ?? double.tryParse(s)?.toInt();
          if (v == null || v < -0x80000000 || v > 0x7fffffff) {
            _fail('$name() value is not a 32-bit integer', at);
          }
          return v;
        case 'NumberLong':
        case 'Long':
        case 'Int64':
          final s = str(0, 'a number');
          final v = int.tryParse(s);
          if (v == null) _fail('$name() value is not a 64-bit integer', at);
          return BsonLong(v);
        case 'NumberDecimal':
        case 'Decimal128':
          return Decimal128.parse(str(0, 'a decimal string'));
        case 'Double':
          final s = str(0, 'a number');
          final v = double.tryParse(s);
          if (v == null) _fail('Double() value is not a number', at);
          return v;
        case 'UUID':
          if (args.isEmpty) return _randomUuid();
          return BsonBinary.uuidFromString(str(0, 'a UUID string'));
        case 'BinData':
          final sub = args.isNotEmpty ? args[0] : null;
          if (sub is! int) _fail('BinData() needs a numeric subtype', at);
          return BsonBinary(sub, base64.decode(str(1, 'base64 data')));
        case 'HexData':
          final sub = args.isNotEmpty ? args[0] : null;
          if (sub is! int) _fail('HexData() needs a numeric subtype', at);
          return BsonBinary(sub, _hexBytes(str(1, 'hex data'), at));
        case 'MD5':
          return BsonBinary(BsonBinary.md5, _hexBytes(str(0, 'hex data'), at));
        case 'Timestamp':
          if (args.length == 1 && args[0] is Map) {
            final m = args[0] as Map;
            return BsonTimestamp(_asInt(m['t'], at), _asInt(m['i'], at));
          }
          if (args.isEmpty) return const BsonTimestamp(0, 0);
          return BsonTimestamp(
            _asInt(args[0], at),
            _asInt(args.length > 1 ? args[1] : 0, at),
          );
        case 'MinKey':
          return BsonMinKey.instance;
        case 'MaxKey':
          return BsonMaxKey.instance;
        case 'RegExp':
        case 'BSONRegExp':
          final flags = args.length > 1 ? str(1, 'flags') : '';
          _checkRegexFlags(flags, at);
          return BsonRegex(str(0, 'a pattern'), _sorted(flags));
        case 'Code':
          final scope = args.length > 1 ? args[1] : null;
          if (scope != null && scope is! Map<String, dynamic>) {
            _fail('Code() scope must be a document', at);
          }
          return BsonCode(str(0, 'code'), scope as Map<String, dynamic>?);
        case 'DBRef':
          final ref = <String, dynamic>{
            r'$ref': str(0, 'a collection'),
            r'$id': args.length > 1 ? args[1] : null,
          };
          if (args.length > 2) ref[r'$db'] = str(2, 'a database');
          return ref;
      }
    } on EJsonParseException {
      rethrow;
    } on FormatException catch (e) {
      _fail('${e.message} in $name()', at);
    } on ArgumentError catch (e) {
      _fail('${e.message} in $name()', at);
    }
    _fail('Unknown function "$name"', at);
  }

  int _asInt(Object? v, int at) {
    if (v is int) return v;
    if (v is BsonLong) return v.value;
    if (v is double && v == v.truncateToDouble()) return v.toInt();
    if (v is String && int.tryParse(v) != null) return int.parse(v);
    _fail('Expected an integer', at);
  }

  Uint8List _hexBytes(String hex, int at) {
    if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
      _fail('Invalid hex data', at);
    }
    final b = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < b.length; i++) {
      b[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return b;
  }

  /// Turns Extended JSON wrapper objects into BSON values. Objects that only
  /// look similar (such as query operators) are returned unchanged.
  Object _convertWrapper(Map<String, dynamic> m, int at) {
    if (m.isEmpty || !m.keys.first.startsWith(r'$')) return m;
    final keys = m.keys.toSet();
    bool only(Set<String> k) => keys.length == k.length && keys.containsAll(k);

    try {
      if (only({r'$oid'}) && m[r'$oid'] is String) {
        return ObjectId.parse(m[r'$oid'] as String);
      }
      if (only({r'$date'})) {
        final d = m[r'$date'];
        if (d is String) return parseIsoDate(d);
        if (d is int) return bsonDateFromMillis(d);
        if (d is BsonLong) return bsonDateFromMillis(d.value);
        if (d is double) return bsonDateFromMillis(d.toInt());
      }
      if (only({r'$numberInt'}) && m[r'$numberInt'] is String) {
        final v = int.parse(m[r'$numberInt'] as String);
        if (v < -0x80000000 || v > 0x7fffffff) {
          _fail(r'$numberInt is out of the 32-bit range', at);
        }
        return v;
      }
      if (only({r'$numberLong'}) && m[r'$numberLong'] is String) {
        return BsonLong(int.parse(m[r'$numberLong'] as String));
      }
      if (only({r'$numberDouble'}) && m[r'$numberDouble'] is String) {
        final s = m[r'$numberDouble'] as String;
        return switch (s) {
          'Infinity' => double.infinity,
          '-Infinity' => double.negativeInfinity,
          'NaN' => double.nan,
          _ => double.parse(s),
        };
      }
      if (only({r'$numberDecimal'}) && m[r'$numberDecimal'] is String) {
        return Decimal128.parse(m[r'$numberDecimal'] as String);
      }
      if (only({r'$binary'}) && m[r'$binary'] is Map) {
        final b = m[r'$binary'] as Map;
        final sub = int.parse('${b['subType']}', radix: 16);
        return BsonBinary(sub, base64.decode(b['base64'] as String));
      }
      if (only({r'$binary', r'$type'}) && m[r'$binary'] is String) {
        final sub = int.parse('${m[r'$type']}', radix: 16);
        return BsonBinary(sub, base64.decode(m[r'$binary'] as String));
      }
      if (only({r'$uuid'}) && m[r'$uuid'] is String) {
        return BsonBinary.uuidFromString(m[r'$uuid'] as String);
      }
      if (only({r'$timestamp'}) && m[r'$timestamp'] is Map) {
        final t = m[r'$timestamp'] as Map;
        return BsonTimestamp(_asInt(t['t'], at), _asInt(t['i'], at));
      }
      if (only({r'$regularExpression'}) && m[r'$regularExpression'] is Map) {
        final r = m[r'$regularExpression'] as Map;
        final options = (r['options'] ?? '') as String;
        _checkRegexFlags(options, at);
        return BsonRegex(r['pattern'] as String, _sorted(options));
      }
      if (only({r'$regex', r'$options'}) &&
          m[r'$regex'] is String &&
          m[r'$options'] is String) {
        final options = m[r'$options'] as String;
        _checkRegexFlags(options, at);
        return BsonRegex(m[r'$regex'] as String, _sorted(options));
      }
      if (only({r'$code'}) && m[r'$code'] is String) {
        return BsonCode(m[r'$code'] as String);
      }
      if (only({r'$code', r'$scope'}) &&
          m[r'$code'] is String &&
          m[r'$scope'] is Map<String, dynamic>) {
        return BsonCode(
          m[r'$code'] as String,
          m[r'$scope'] as Map<String, dynamic>,
        );
      }
      if (only({r'$symbol'}) && m[r'$symbol'] is String) {
        return BsonSymbol(m[r'$symbol'] as String);
      }
      if (only({r'$dbPointer'}) && m[r'$dbPointer'] is Map) {
        final p = m[r'$dbPointer'] as Map;
        final id = p[r'$id'];
        if (p[r'$ref'] is String && id is ObjectId) {
          return BsonDbPointer(p[r'$ref'] as String, id);
        }
      }
      if (only({r'$undefined'}) && m[r'$undefined'] == true) {
        return BsonUndefined.instance;
      }
      if (only({r'$minKey'}) && m[r'$minKey'] == 1) return BsonMinKey.instance;
      if (only({r'$maxKey'}) && m[r'$maxKey'] == 1) return BsonMaxKey.instance;
    } on EJsonParseException {
      rethrow;
    } on FormatException catch (e) {
      _fail('Invalid ${m.keys.first} value: ${e.message}', at);
    } on TypeError {
      _fail('Invalid ${m.keys.first} value', at);
    }
    return m;
  }
}

/// Parses an ISO-8601 date. A date without a time zone is taken as UTC.
Object parseIsoDate(String s) {
  var t = s.trim();
  final hasZone = RegExp(
    r'(Z|[+-]\d\d:?\d\d)$',
    caseSensitive: false,
  ).hasMatch(t);
  if (RegExp(r'^[+-]?\d{4,6}-\d\d-\d\d$').hasMatch(t)) t = '${t}T00:00:00';
  if (!hasZone && t.contains(RegExp(r'\d{4}-\d\d-\d\d'))) t = '${t}Z';
  final d = DateTime.tryParse(t);
  if (d == null) throw FormatException('Invalid date', s);
  return d.toUtc();
}

String _numText(num v) => v is double ? formatNum(v) : '$v';

String formatNum(double v) =>
    v == v.truncateToDouble() && v.abs() < 1e18 ? '${v.toInt()}' : '$v';

String _sorted(String flags) => (flags.split('')..sort()).join();

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 48 && u <= 57;
}

bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || c == '_' || c == r'$';
}

bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);

BsonBinary _randomUuid() {
  final r = Random.secure();
  final b = Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return BsonBinary(BsonBinary.uuid, b);
}
