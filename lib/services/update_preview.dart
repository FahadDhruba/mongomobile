import 'dart:typed_data';

import 'package:mongo_wire/mongo_wire.dart';

/// Thrown when an update uses something the preview cannot simulate; the
/// update itself may still be fine on the server.
class PreviewUnsupported implements Exception {
  const PreviewUnsupported(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Checks the shape of an update: a document of update operators, or a
/// non-empty pipeline. Returns a short problem, or null.
String? updateShapeError(Object? update) {
  if (update is List) {
    if (update.isEmpty) return 'The pipeline is empty';
    for (final s in update) {
      if (s is! Map || s.length != 1 || !'${s.keys.first}'.startsWith(r'$')) {
        return 'Each pipeline stage needs exactly one \$operator';
      }
    }
    return null;
  }
  if (update is! Map || update.isEmpty) {
    return r'Enter an update such as { $set: { field: value } }';
  }
  for (final k in update.keys) {
    if (!'$k'.startsWith(r'$')) {
      return '"$k" is not an update operator. To replace whole documents, '
          'edit them one by one.';
    }
    if (update[k] is! Map) return '$k needs a document';
  }
  return null;
}

/// Applies the update operators in [update] to a copy of [doc], as the
/// server would for the common operators. Throws [PreviewUnsupported] for
/// operators or paths it does not handle, and [FormatException] for
/// updates the server would reject.
Map<String, dynamic> applyUpdate(
  Map<String, dynamic> doc,
  Map<String, dynamic> update,
) {
  final out = _deepCopy(doc) as Map<String, dynamic>;
  // Like the server (5.0+), apply the paths in lexicographic order, so new
  // fields are added in that order.
  final steps = [
    for (final MapEntry(key: op, value: spec) in update.entries)
      for (final MapEntry(key: k, value: v) in (spec as Map).entries)
        (op: op, path: '$k', v: v),
  ]..sort((a, b) => a.path.compareTo(b.path));
  for (final (:op, :path, :v) in steps) {
    if (path.split('.').any((p) => p.startsWith(r'$') || p.isEmpty)) {
      throw PreviewUnsupported('Positional paths like "$path"');
    }
    if (path == '_id' || path.startsWith('_id.')) {
      if (op != r'$set' || !_same(_get(out, path), v)) {
        throw const FormatException('The _id of a document cannot be changed');
      }
    }
    switch (op) {
      case r'$set':
        _set(out, path, _deepCopy(v));
      case r'$unset':
        _unset(out, path);
      case r'$inc' || r'$mul':
        // A missing field starts at 0, typed like the amount.
        final cur = _get(out, path);
        _set(
          out,
          path,
          _arith(op == r'$inc' ? '+' : '*', cur == _missing ? 0 : cur, v, path),
        );
      case r'$rename':
        if (v is! String) throw FormatException('$op needs a field name');
        final cur = _get(out, path);
        if (cur == _missing) continue;
        _unset(out, path);
        _set(out, v, cur);
      case r'$currentDate':
        final now = DateTime.now().toUtc();
        if (v is Map && v[r'$type'] == 'timestamp') {
          throw const PreviewUnsupported(r'$currentDate as a timestamp');
        }
        _set(
          out,
          path,
          DateTime.fromMillisecondsSinceEpoch(
            now.millisecondsSinceEpoch,
            isUtc: true,
          ),
        );
      case r'$push' || r'$addToSet':
        final cur = _get(out, path);
        final list = cur == _missing ? <Object?>[] : cur;
        if (list is! List) {
          throw FormatException('"$path" is not an array');
        }
        List<Object?> items;
        if (v is Map && v.containsKey(r'$each')) {
          if (v.keys.any((key) => key != r'$each')) {
            throw PreviewUnsupported(
              '$op with ${v.keys.where((key) => key != r'$each').join(', ')}',
            );
          }
          items = List.of(v[r'$each'] as List);
        } else {
          items = [v];
        }
        final next = List<Object?>.of(list);
        for (final item in items) {
          if (op == r'$addToSet' && next.any((e) => _same(e, item))) continue;
          next.add(_deepCopy(item));
        }
        _set(out, path, next);
      case r'$pull':
        final cur = _get(out, path);
        if (cur == _missing) continue;
        if (cur is! List) throw FormatException('"$path" is not an array');
        if (v is Map && v.keys.any((key) => '$key'.startsWith(r'$'))) {
          throw const PreviewUnsupported(r'$pull with a condition');
        }
        _set(out, path, [
          for (final e in cur)
            if (!_same(e, v)) e,
        ]);
      case r'$pop':
        final cur = _get(out, path);
        if (cur == _missing) continue;
        if (cur is! List) throw FormatException('"$path" is not an array');
        final next = List<Object?>.of(cur);
        if (next.isNotEmpty) {
          v == -1 ? next.removeAt(0) : next.removeLast();
        }
        _set(out, path, next);
      default:
        throw PreviewUnsupported(op);
    }
  }
  return out;
}

const _missing = Object();

Object? _get(Map<String, dynamic> doc, String path) {
  Object? cur = doc;
  for (final part in path.split('.')) {
    if (cur is Map && cur.containsKey(part)) {
      cur = cur[part];
    } else if (_index(cur, part) case final i?) {
      cur = (cur! as List)[i];
    } else {
      return _missing;
    }
  }
  return cur;
}

void _set(Map<String, dynamic> doc, String path, Object? value) {
  final parts = path.split('.');
  Object? cur = doc;
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final last = i == parts.length - 1;
    if (cur is Map) {
      if (last) {
        cur[part] = value;
        return;
      }
      cur = cur.putIfAbsent(part, () => <String, dynamic>{});
    } else if (cur is List) {
      final index = int.tryParse(part);
      if (index == null) {
        throw FormatException('Cannot create field "$part" in an array');
      }
      while (cur.length <= index) {
        cur.add(null);
      }
      if (last) {
        cur[index] = value;
        return;
      }
      cur[index] ??= <String, dynamic>{};
      cur = cur[index];
    } else {
      throw FormatException(
        'Cannot create field "$part" in "${parts.take(i).join('.')}"',
      );
    }
  }
}

void _unset(Map<String, dynamic> doc, String path) {
  final parts = path.split('.');
  final parent = parts.length == 1
      ? doc
      : _get(doc, parts.sublist(0, parts.length - 1).join('.'));
  if (parent is Map) {
    parent.remove(parts.last);
  } else if (_index(parent, parts.last) case final i?) {
    // $unset on an array element sets it to null.
    (parent! as List)[i] = null;
  }
}

/// [part] as an index into [list], or null when it is not one.
int? _index(Object? list, String part) {
  if (list is! List) return null;
  final i = int.tryParse(part);
  return i != null && i >= 0 && i < list.length ? i : null;
}

Object _arith(String op, Object? a, Object? b, String path) {
  num? asNum(Object? x) => switch (x) {
    int() => x,
    double() => x,
    BsonLong() => x.value,
    _ => null,
  };
  if (a is Decimal128 || b is Decimal128) {
    throw const PreviewUnsupported('Decimal128 arithmetic');
  }
  final x = asNum(a);
  final y = asNum(b);
  if (y == null) throw FormatException('"$path": the amount must be a number');
  if (x == null) {
    throw FormatException('"$path" holds a non-number value');
  }
  final r = op == '+' ? x + y : x * y;
  if (a is double || b is double) return r.toDouble();
  if (a is BsonLong || b is BsonLong) return BsonLong(r.toInt());
  final n = r.toInt();
  return n >= -0x80000000 && n <= 0x7fffffff ? n : BsonLong(n);
}

bool _same(Object? a, Object? b) {
  try {
    final x = Bson.encode({'v': a});
    final y = Bson.encode({'v': b});
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  } on BsonException {
    return false;
  }
}

Object? _deepCopy(Object? v) => switch (v) {
  Map() => <String, dynamic>{
    for (final e in v.entries) '${e.key}': _deepCopy(e.value),
  },
  Uint8List() => Uint8List.fromList(v),
  List() => [for (final e in v) _deepCopy(e)],
  _ => v,
};
