import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/update_preview.dart';

void main() {
  Map<String, dynamic> base() => {
    '_id': 1,
    'n': 5,
    'l': const BsonLong(5),
    'd': 1.5,
    'tags': ['a', 'b'],
    'a': {'b': 1},
  };

  test('checks the update shape', () {
    expect(updateShapeError({r'$set': {'a': 1}}), isNull);
    expect(updateShapeError({'a': 1}), contains('not an update operator'));
    expect(updateShapeError(<String, dynamic>{}), isNotNull);
    expect(updateShapeError([]), 'The pipeline is empty');
    expect(updateShapeError([{r'$set': {'a': 1}}]), isNull);
    expect(updateShapeError([{'a': 1}]), isNotNull);
    expect(updateShapeError({r'$set': 1}), r'$set needs a document');
  });

  test('set, unset and dotted paths', () {
    final d = base();
    final r = applyUpdate(d, {
      r'$set': {'x': 1, 'a.c': 2, 'new.deep': true, 'tags.1': 'z'},
      r'$unset': {'d': ''},
    });
    expect(r['x'], 1);
    expect(r['a'], {'b': 1, 'c': 2});
    expect(r['new'], {'deep': true});
    expect(r['tags'], ['a', 'z']);
    expect(r.containsKey('d'), isFalse);
    // The original is untouched.
    expect(d['tags'], ['a', 'b']);
    expect(d.containsKey('x'), isFalse);
  });

  test('arithmetic keeps BSON number types', () {
    final r = applyUpdate(base(), {
      r'$inc': {'n': 2, 'l': 1, 'd': 1, 'missing': const BsonLong(3)},
      r'$mul': {'m2': 4.0},
    });
    expect(r['n'], 7);
    expect(r['l'], const BsonLong(6));
    expect(r['d'], 2.5);
    expect(r['missing'], const BsonLong(3));
    expect(r['m2'], 0.0);
    expect(
      applyUpdate(base(), {
        r'$inc': {'n': 0x7fffffff},
      })['n'],
      const BsonLong(0x7fffffff + 5),
    );
    expect(
      () => applyUpdate(base(), {
        r'$inc': {'tags': 1},
      }),
      throwsFormatException,
    );
  });

  test('array operators', () {
    final r = applyUpdate(base(), {
      r'$push': {
        'tags': {
          r'$each': ['c', 'd'],
        },
      },
      r'$addToSet': {'set': 'x'},
    });
    expect(r['tags'], ['a', 'b', 'c', 'd']);
    expect(r['set'], ['x']);
    expect(
      applyUpdate(base(), {
        r'$addToSet': {'tags': 'a'},
      })['tags'],
      ['a', 'b'],
    );
    expect(
      applyUpdate(base(), {
        r'$pull': {'tags': 'a'},
      })['tags'],
      ['b'],
    );
    expect(
      applyUpdate(base(), {
        r'$pop': {'tags': -1},
      })['tags'],
      ['b'],
    );
  });

  test('rename and the _id guard', () {
    final r = applyUpdate(base(), {
      r'$rename': {'n': 'count'},
    });
    expect(r.containsKey('n'), isFalse);
    expect(r['count'], 5);
    expect(
      () => applyUpdate(base(), {
        r'$set': {'_id': 2},
      }),
      throwsFormatException,
    );
    expect(
      applyUpdate(base(), {
        r'$set': {'_id': 1},
      })['_id'],
      1,
    );
  });

  test('reports what it cannot simulate', () {
    for (final u in [
      {
        r'$min': {'n': 1},
      },
      {
        r'$set': {r'tags.$': 'x'},
      },
      {
        r'$pull': {
          'tags': {r'$in': ['a']},
        },
      },
      {
        r'$push': {
          'tags': {
            r'$each': ['x'],
            r'$slice': 2,
          },
        },
      },
    ]) {
      expect(
        () => applyUpdate(base(), u),
        throwsA(isA<PreviewUnsupported>()),
        reason: '$u',
      );
    }
  });
}
