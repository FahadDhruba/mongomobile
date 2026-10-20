import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/field_model.dart';

void main() {
  final doc = <String, dynamic>{
    '_id': ObjectId.parse('65a1b2c3d4e5f60718293a4b'),
    'name': 'Ada',
    'age': 36,
    'big': const BsonLong(1 << 40),
    'score': 9.5,
    'price': Decimal128.parse('19.99'),
    'active': true,
    'born': DateTime.utc(1815, 12, 10),
    'nothing': null,
    'address': {'city': 'London', 'zip': 'N1'},
    'tags': ['math', 'poetry'],
    'blob': BsonBinary(0x80, [1, 2]),
    're': const BsonRegex('a', 'i'),
  };

  test('round-trips every type unchanged', () {
    final root = documentNode(doc);
    expect(root.error(), isNull);
    expect(Bson.encode(root.value() as Map<String, dynamic>), Bson.encode(doc));
  });

  test('reports the first invalid field with its path', () {
    final root = documentNode(doc);
    root.children.firstWhere((c) => c.key == 'age').text = 'abc';
    expect(root.error(), 'age: Enter a whole number (32-bit)');
    final address = root.children.firstWhere((c) => c.key == 'address');
    root.children.firstWhere((c) => c.key == 'age').text = '37';
    address.children.first.key = 'zip';
    expect(root.error(), 'address: "zip" appears twice');
  });

  test('changes types keeping the value where it makes sense', () {
    final n = FieldNode.fromValue('n', '42');
    n.changeType(FieldType.int32);
    expect(n.value(), 42);
    n.changeType(FieldType.double_);
    expect(n.value(), 42.0);
    n.changeType(FieldType.int64);
    expect(n.value(), const BsonLong(42));
    n.changeType(FieldType.string);
    expect(n.value(), '42');

    final d = FieldNode.fromValue('d', DateTime.utc(2024));
    d.changeType(FieldType.int64);
    expect(d.value(), BsonLong(DateTime.utc(2024).millisecondsSinceEpoch));
    d.changeType(FieldType.date);
    expect(d.value(), DateTime.utc(2024));

    final s = FieldNode.fromValue('s', 'x');
    s.changeType(FieldType.array);
    expect(s.value(), ['x']);
    s.changeType(FieldType.object);
    expect(s.value(), {'field0': 'x'});

    final o = FieldNode.fromValue('o', 'not hex');
    o.changeType(FieldType.objectId);
    expect(o.value(), isA<ObjectId>());

    final b = FieldNode.fromValue('b', 'yes');
    b.changeType(FieldType.boolean);
    expect(b.value(), false);
  });

  test('adds and removes children, renumbering arrays', () {
    final arr = FieldNode.fromValue('a', [1, 2, 3]);
    arr.removeChild(arr.children[0]);
    expect(arr.children.map((c) => c.key), ['0', '1']);
    arr.addChild().text = 'new';
    expect(arr.value(), [2, 3, 'new']);
    final obj = FieldNode.fromValue('o', <String, dynamic>{});
    final child = obj.addChild();
    expect(obj.error(), 'o: a field has no name');
    child.key = 'k';
    expect(obj.value(), {'k': ''});
  });

  test('other types stay as they were', () {
    final n = FieldNode.fromValue('r', const BsonRegex('x', 'm'));
    expect(n.type, FieldType.other);
    expect(n.value(), const BsonRegex('x', 'm'));
  });
}
