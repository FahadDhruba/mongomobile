import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/services/schema_analysis.dart';

void main() {
  final docs = <Map<String, dynamic>>[
    {
      '_id': 1,
      'name': 'Ada',
      'age': 36,
      'tags': ['a', 'b'],
      'address': {'city': 'London'},
      'items': [
        {'sku': 'A', 'qty': 1},
        {'sku': 'B'},
      ],
    },
    {
      '_id': 2,
      'name': 'Alan',
      'age': null,
      'tags': <Object?>[],
      'address': {'city': 'Wilmslow', 'zip': 'SK9'},
    },
    {'_id': 3, 'name': 'Ada', 'age': const BsonLong(41)},
    {'_id': 4, 'age': 2.5},
  ];

  test('counts fields and types', () {
    final s = SchemaAnalysis.of(docs);
    expect(s.documents, 4);
    expect(s.sortedFields.map((f) => f.name).first, '_id');
    final age = s.fields['age']!;
    expect(age.count, 4);
    expect(
      {for (final t in age.sortedTypes) t.name: t.count},
      {'Int32': 1, 'Null': 1, 'Int64': 1, 'Double': 1},
    );
    final name = s.fields['name']!;
    expect(name.count, 3);
    expect(topValues(name.types['String']!.values).first, (
      value: 'Ada',
      count: 2,
    ));
    expect(distinctCount(name.types['String']!.values), 2);
  });

  test('nested documents and arrays', () {
    final s = SchemaAnalysis.of(docs);
    final address = s.fields['address']!.types['Object']!;
    expect(address.documents, 2);
    expect(address.fields['city']!.count, 2);
    expect(address.fields['zip']!.count, 1);
    expect(address.fields['zip']!.path, 'address.zip');

    final tags = s.fields['tags']!.types['Array']!;
    expect(tags.lengths, [2, 0]);
    expect(tags.itemTypes['String']!.count, 2);

    final items = s.fields['items']!.types['Array']!.itemTypes['Object']!;
    expect(items.documents, 2);
    expect(items.fields['sku']!.count, 2);
    expect(items.fields['qty']!.count, 1);
    expect(items.fields['qty']!.path, 'items.qty');
  });

  test('histogram buckets', () {
    expect(histogram([1, 2, 3, 4], bins: 2), [2, 2]);
    expect(histogram([5, 5], bins: 3), [2, 0, 0]);
    expect(histogram([double.nan]), isEmpty);
    expect(numericValue(const BsonLong(3)), 3);
    expect(numericValue('x'), isNull);
  });
}
