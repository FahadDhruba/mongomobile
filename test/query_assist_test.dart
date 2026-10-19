import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mongomobile/ui/widgets/query_assist.dart';

/// `|` marks the cursor.
TextEditingValue v(String s) {
  final i = s.indexOf('|');
  return TextEditingValue(
      text: s.replaceFirst('|', ''),
      selection: TextSelection.collapsed(offset: i));
}

String show(TextEditingValue t) =>
    t.text.replaceRange(t.selection.baseOffset, t.selection.baseOffset, '|');

/// Types [ch] at the cursor of [before] through the formatter.
String type(String before, String ch, {bool wrap = true}) {
  final old = v(before);
  final at = old.selection.baseOffset;
  final typed = TextEditingValue(
    text: old.text.replaceRange(at, at, ch),
    selection: TextSelection.collapsed(offset: at + 1),
  );
  return show(QueryInputFormatter(wrapInBraces: wrap).formatEditUpdate(old, typed));
}

String backspace(String before) {
  final old = v(before);
  final at = old.selection.baseOffset;
  final edited = TextEditingValue(
    text: old.text.replaceRange(at - 1, at, ''),
    selection: TextSelection.collapsed(offset: at - 1),
  );
  return show(QueryInputFormatter().formatEditUpdate(old, edited));
}

List<String> labels(QueryField f, String text, List<String> fields) {
  final t = v(text);
  final ctx = analyzeQuery(t.text, t.selection.baseOffset);
  if (ctx == null) return const [];
  return suggestQuery(f, ctx, fields).map((s) => s.label).toList();
}

String pick(QueryField f, String text, List<String> fields, String label) {
  final t = v(text);
  final ctx = analyzeQuery(t.text, t.selection.baseOffset)!;
  final s = suggestQuery(f, ctx, fields).firstWhere((s) => s.label == label);
  return show(applySuggestion(t, ctx, s));
}

const fields = ['_id', 'name', 'age', 'address', 'address.city', 'tags'];

void main() {
  group('auto closing', () {
    test('wraps the first character of an empty input in braces', () {
      expect(type('|', 'n'), '{ n| }');
      expect(type('|', '{'), '{|}');
      expect(type('|', '"'), '{ "|" }');
      expect(type('|', 'n', wrap: false), 'n|');
    });

    test('closes brackets and quotes', () {
      expect(type('{ a: |}', '['), '{ a: [|]}');
      expect(type('{ a: |}', '{'), '{ a: {|}}');
      expect(type('{ a: |}', "'"), "{ a: '|'}");
      expect(type('{ a: ObjectId|}', '('), '{ a: ObjectId(|)}');
    });

    test('steps over an existing closer', () {
      expect(type('{ a: [1|] }', ']'), '{ a: [1]| }');
      expect(type("{ a: 'x|' }", "'"), "{ a: 'x'| }");
      expect(type('{ a: 1 |}', '}'), '{ a: 1 }|');
    });

    test('does not pair in the middle of a word', () {
      expect(type("{ a: it|s }", "'"), "{ a: it'|s }");
      expect(type('{ a: |x }', '['), '{ a: [|x }');
    });

    test('backspace removes an empty pair', () {
      expect(backspace('{ a: [|] }'), '{ a: | }');
      expect(backspace("{ a: '|' }"), '{ a: | }');
      expect(backspace('{ a: [1|] }'), '{ a: [|] }');
    });
  });

  group('suggestions', () {
    test('fields in key position, best matches first', () {
      expect(labels(QueryField.filter, '{ |}', fields), [
        '_id', 'name', 'age', 'address', 'address.city', 'tags',
      ]);
      expect(labels(QueryField.filter, '{ ad|}', fields),
          ['address', 'address.city']);
      expect(labels(QueryField.filter, '{ name: 1, ci|}', fields),
          ['address.city']);
      expect(labels(QueryField.filter, '{ "na|" }', fields), ['name']);
    });

    test('operators under a field and after a dollar sign', () {
      expect(labels(QueryField.filter, '{ age: { |} }', fields).first, r'$eq');
      expect(labels(QueryField.filter, r'{ age: { $g| } }', fields),
          [r'$gt', r'$gte']);
      expect(labels(QueryField.filter, r'{ $o| }', fields),
          [r'$or', r'$options']);
    });

    test(r'fields again inside $and / $or arrays', () {
      expect(labels(QueryField.filter, r'{ $or: [ { na| } ] }', fields),
          ['name']);
    });

    test('value helpers in value position', () {
      expect(labels(QueryField.filter, '{ _id: Obj| }', fields),
          ["ObjectId('')"]);
      expect(labels(QueryField.filter, '{ _id: | }', fields),
          contains("ISODate('')"));
      expect(labels(QueryField.sort, '{ age: | }', fields), ['1', '-1']);
    });

    test('nothing inside string values or for project operators', () {
      expect(labels(QueryField.filter, '{ name: "Ad|" }', fields), isEmpty);
      expect(labels(QueryField.project, r'{ $| }', fields), isEmpty);
    });
  });

  group('applying a suggestion', () {
    test('completes a field and adds ": "', () {
      expect(pick(QueryField.filter, '{ na| }', fields, 'name'), '{ name: | }');
    });

    test('quotes dotted paths', () {
      expect(pick(QueryField.filter, '{ ci| }', fields, 'address.city'),
          "{ 'address.city': | }");
      expect(pick(QueryField.filter, '{ "ci|" }', fields, 'address.city'),
          '{ "address.city": | }');
    });

    test('keeps an existing colon', () {
      expect(pick(QueryField.filter, '{ na|: 1 }', fields, 'name'),
          '{ name: |1 }');
    });

    test('operators and value helpers', () {
      expect(pick(QueryField.filter, r'{ age: { $g| } }', fields, r'$gte'),
          r'{ age: { $gte: | } }');
      expect(pick(QueryField.filter, '{ _id: Obj| }', fields, "ObjectId('')"),
          "{ _id: ObjectId('|') }");
    });
  });

  test('collects dotted field paths through arrays', () {
    expect(
      fieldPathsOf([
        {
          'name': 'a',
          '_id': 1,
          'address': {'city': 'x'},
          'items': [
            {'sku': 'a'},
            {'qty': 1},
          ],
        },
        {'extra': true},
      ]),
      ['_id', 'name', 'address', 'address.city', 'items', 'items.sku', 'items.qty', 'extra'],
    );
  });
}
