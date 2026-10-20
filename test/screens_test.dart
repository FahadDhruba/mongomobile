import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_wire/mongo_wire.dart';
import 'package:mongomobile/app.dart';
import 'package:mongomobile/models/app_settings.dart';
import 'package:mongomobile/models/connection_profile.dart';
import 'package:mongomobile/services/exporter.dart';
import 'package:mongomobile/services/importer.dart';
import 'package:mongomobile/services/native.dart';
import 'package:mongomobile/state/providers.dart';
import 'package:mongomobile/state/query_library.dart';
import 'package:mongomobile/theme/app_theme.dart';
import 'package:mongomobile/ui/screens/aggregations_view.dart';
import 'package:mongomobile/ui/screens/code_export_sheet.dart';

import 'support/fake_client.dart';

/// Walks through the main screens with a fake server. With SCREENSHOT_DIR
/// set, each step is also saved as a PNG for review.
final String? shotDir = Platform.environment['SCREENSHOT_DIR'];
final _boundary = GlobalKey();

Future<void> loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(File(f).readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await loader.load();
  }

  await load('Inter', [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
    'assets/fonts/Inter-Bold.ttf',
  ]);
  await load('JetBrainsMono', [
    'assets/fonts/JetBrainsMono-Regular.ttf',
    'assets/fonts/JetBrainsMono-Bold.ttf',
  ]);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await load('MaterialIcons', [icons.path]);
}

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  if (shotDir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shotDir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Map<String, Map<String, List<Map<String, dynamic>>>> sampleData() {
  final docs = <Map<String, dynamic>>[
    for (var i = 0; i < 40; i++)
      {
        '_id': ObjectId.parse('65a1b2c3d4e5f60718293a${i.toRadixString(16).padLeft(2, '0')}'),
        'orderNo': 1000 + i,
        'customer': {
          'name': ['Ada Lovelace', 'Alan Turing', 'Grace Hopper'][i % 3],
          'email': 'user$i@example.com',
          'address': {'city': 'London', 'zip': 'N1 9GU'},
        },
        'items': [
          {'sku': 'A-1', 'qty': 2, 'price': Decimal128.parse('19.99')},
          {'sku': 'B-7', 'qty': 1, 'price': Decimal128.parse('5.50')},
        ],
        'paid': i.isEven,
        'total': 45.48 + i,
        'placedAt': DateTime.utc(2024, 5, 1 + (i % 28), 9, 30),
        'notes': i == 0 ? 'Leave at the door. ' * 40 : null,
        'version': BsonLong(3 + i),
      },
  ];
  return {
    'shop': {'orders': docs, 'customers': [], 'products': []},
    'analytics': {'events': []},
  };
}

class TextSource implements ImportSource {
  TextSource(this.name, this.text);
  final String text;
  @override
  final String name;
  @override
  int? get size => text.length;
  @override
  Stream<List<int>> read() => Stream.value(text.codeUnits);
}

/// Hands out [file] instead of opening Android's picker.
class FakeFiles extends NativeFiles {
  FakeFiles(this.file);
  ImportSource? file;
  final written = <String, List<int>>{};

  @override
  Future<ImportSource?> open(List<String> mimeTypes) async => file;

  @override
  Future<ExportSink?> create(String name, String mimeType) async =>
      _MemorySink(written[name] = []);
}

class _MemorySink implements ExportSink {
  _MemorySink(this.bytes);
  final List<int> bytes;
  @override
  Future<void> add(List<int> b) async => bytes.addAll(b);
  @override
  Future<void> close() async {}
  @override
  Future<void> abort() async {}
}

Future<void> pumpApp(WidgetTester tester, FakeMongoClient client,
    MemoryConnectionStore store,
    {AppSettings settings = const AppSettings(), NativeFiles? files}) async {
  tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        connectorProvider.overrideWithValue(FakeConnector(client)),
        connectionStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(settings),
        settingsStoreProvider.overrideWithValue(MemorySettingsStore()),
        queryLibraryStoreProvider.overrideWithValue(MemoryQueryLibraryStore()),
        if (files != null) nativeFilesProvider.overrideWithValue(files),
      ],
      retry: (_, _) => null,
      child: RepaintBoundary(key: _boundary, child: const MongoMobileApp()),
    ),
  );
}

void main() {
  setUpAll(() async {
    await loadFonts();
  });

  testWidgets('connect, browse, page, view and edit', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore();
    await pumpApp(tester, client, store);
    await shot(tester, '01-connections-empty');
    expect(find.text('No connections yet'), findsOneWidget);

    store.saved = [
      const ConnectionProfile(
          id: 'a',
          name: 'Local dev',
          uri: 'mongodb://root:secret@localhost:27017/?authSource=admin'),
      const ConnectionProfile(
          id: 'b',
          name: 'Atlas production',
          uri: 'mongodb+srv://app:pw@cluster0.abcde.mongodb.net/',
          colorIndex: 3),
    ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await shot(tester, '02-connections');
    expect(find.text('Local dev'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);

    await tester.tap(find.text('New connection').last);
    await shot(tester, '03-connection-edit');
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Local dev'));
    await shot(tester, '04-workspace-overview');
    expect(find.text('Standalone'), findsWidgets);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await shot(tester, '05-drawer');
    expect(find.text('orders'), findsOneWidget);

    await tester.tap(find.text('orders'));
    await shot(tester, '06-documents');
    expect(find.text('1 – 25 of ~40'), findsOneWidget);
    expect(find.textContaining("ObjectId('65a1b2c3d4e5f60718293a00')"),
        findsOneWidget);

    await tester.tap(find.textContaining('customer', findRichText: true).first);
    await shot(tester, '07-documents-expanded');

    await tester.tap(find.byTooltip('Next page'));
    await shot(tester, '08-page-2');
    expect(find.text('26 – 40 of 40'), findsOneWidget);

    await tester.tap(find.byTooltip('JSON view'));
    await shot(tester, '09-json-view');

    await tester.tap(find.byTooltip('Table view'));
    await shot(tester, '09b-table-view');
    expect(find.text('orderNo'), findsOneWidget);
    await tester.tap(find.text('1025'));
    await shot(tester, '09c-table-cell');
    expect(find.text('Int32'), findsOneWidget);
    Navigator.of(tester.element(find.text('Int32'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('JSON view'));
    await tester.pumpAndSettle();

    // Read-only by default: no edit actions until write mode is on.
    expect(find.byTooltip('Edit'), findsNothing);
    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit'), findsWidgets);
    await tester.tap(find.byTooltip('List view'));
    await tester.tap(find.byTooltip('Previous page'));
    await shot(tester, '10-write-mode');

    await tester.tap(find.byTooltip('Edit').first);
    await shot(tester, '11-editor');
    expect(find.text('Valid document'), findsOneWidget);

    // The field editor: _id is locked, bad values block saving.
    await tester.tap(find.byTooltip('Field editor'));
    await shot(tester, '11a-field-editor');
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    final orderNo = find.widgetWithText(TextFormField, '1000');
    await tester.enterText(orderNo, 'abc');
    await tester.pump();
    expect(find.textContaining('orderNo: Enter a whole number'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'abc'), '4242');
    await tester.pump();
    expect(find.text('Valid document'), findsOneWidget);
    // Back to JSON and forth keeps the edit.
    await tester.tap(find.byTooltip('JSON editor'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"orderNo": 4242'), findsOneWidget);
    await tester.tap(find.byTooltip('Field editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(client.data['shop']!['orders']!.first['orderNo'], 4242);
    expect(client.data['shop']!['orders']!.first['version'], BsonLong(3));

    // Typing in the filter closes braces and suggests fields.
    final filter = find.byType(TextField).first;
    await tester.tap(filter);
    await tester.pump();
    await tester.enterText(filter, '{ cus');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ActionChip, 'customer.name'), findsOneWidget);
    await shot(tester, '11b-suggestions');
    await tester.tap(find.widgetWithText(ActionChip, 'customer.name'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(filter).controller!.text,
        "{ 'customer.name': ");
    await tester.enterText(filter, '');
    await tester.pump();

    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '{ paid: true, ');
    await tester.tap(find.text('Find'));
    await shot(tester, '12-query-error');
    expect(find.textContaining('Filter:'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '{ paid: true }');
    await tester.tap(find.text('Find'));
    await shot(tester, '13-filtered');
    expect(find.text('1 – 20 of 20'), findsOneWidget);

    await tester.tap(find.text('Indexes'));
    await shot(tester, '14-indexes');
    expect(find.text('_id_'), findsOneWidget);

    await tester.tap(find.text('Create Index'));
    await shot(tester, '15-create-index');
  });

  testWidgets('light theme', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store,
        settings: const AppSettings(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await shot(tester, '20-light-documents');
    expect(find.text('1 – 25 of ~40'), findsOneWidget);
  });

  testWidgets('edit a table cell in place', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Table view'));
    await tester.pumpAndSettle();

    // Read-only: the value sheet has no Edit button.
    await tester.tap(find.text('1001'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    Navigator.of(tester.element(find.text('Int32'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1001'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit field'), findsOneWidget);
    await tester.tap(find.byTooltip('Field type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Int64').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '1001'), '777777');
    await tester.pump();
    await shot(tester, '16-table-edit');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final orders = client.data['shop']!['orders']!;
    expect(orders[1]['orderNo'], const BsonLong(777777));
    expect(find.text('777777'), findsOneWidget);

    // Remove a field.
    await tester.tap(find.text('777777'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove field'));
    await tester.pumpAndSettle();
    expect(orders[1].containsKey('orderNo'), isFalse);
  });

  testWidgets('bulk update and delete', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '{ paid: true }');
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();

    // Read-only: the bulk actions are disabled.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update documents…'));
    await tester.pumpAndSettle();
    expect(find.text('Update documents'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update documents…'));
    await tester.pumpAndSettle();
    expect(find.text('20 documents match'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      r"{ $set: { status: 'shipped' }, $inc: { version: 1 } }",
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Changes: version, status'), findsWidgets);
    await shot(tester, '17-bulk-update');
    await tester.tap(find.text('Update 20 documents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update').last);
    await tester.pumpAndSettle();
    expect(find.text('Updated 20 of 20 matching documents'), findsOneWidget);
    final orders = client.data['shop']!['orders']!;
    expect(orders.where((d) => d['status'] == 'shipped').length, 20);
    expect(orders[0]['version'], const BsonLong(4));
    expect(orders[1]['version'], const BsonLong(4));

    // A bad update is caught before it is sent.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update documents…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "{ status: 'x' }");
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.textContaining('is not an update operator'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete documents…'));
    await tester.pumpAndSettle();
    await shot(tester, '18-bulk-delete');
    await tester.tap(find.text('Delete 20 documents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(find.text('Deleted 20 documents'), findsOneWidget);
    expect(orders.length, 20);
    expect(orders.every((d) => d['paid'] == false), isTrue);
  });

  testWidgets('import a CSV file', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    final files = FakeFiles(TextSource(
      'people.csv',
      'name;age;joined;address.city\nAda;36;2024-05-01;London\n'
          'Alan;41;2024-06-02;Wilmslow\nGrace;x;2024-07-03;\n',
    ));
    await pumpApp(tester, client, store, files: files);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('customers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import data'));
    await tester.pumpAndSettle();

    expect(find.text('people.csv'), findsOneWidget);
    expect(find.text('Semicolon'), findsOneWidget);
    expect(find.text('address.city'), findsOneWidget);
    // "x" in the age column makes it a string; switch it to Int32.
    await tester.tap(find.byTooltip('Type of age'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Int32').last);
    await tester.pumpAndSettle();
    await shot(tester, '19-import-options');
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.text('Import finished with errors'), findsOneWidget);
    expect(find.textContaining('Row 4: age'), findsOneWidget);
    await shot(tester, '19b-import-done');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Imported 2 documents'), findsOneWidget);
    final docs = client.data['shop']!['customers']!;
    expect(docs.length, 2);
    expect(docs[0]['age'], 36);
    expect(docs[0]['joined'], DateTime.utc(2024, 5, 1));
    expect(docs[1]['address'], {'city': 'Wilmslow'});

    // Cancelling the picker leaves the screen.
    files.file = null;
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import data'));
    await tester.pumpAndSettle();
    expect(find.text('Import into customers'), findsNothing);
  });

  testWidgets('create, rename and drop databases and collections',
      (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();

    // Read-only blocks it.
    await tester.tap(find.text('Create database'));
    await tester.pumpAndSettle();
    expect(find.text('Turn on write mode to create databases'), findsOneWidget);

    void clearSnacks() => tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    clearSnacks();
    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create database'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a database name'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Database name'), 'metrics');
    await tester.enterText(
        find.widgetWithText(TextField, 'Collection name'), 'readings');
    await tester.tap(find.text('Time series'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Time field'), 'ts');
    await tester.enterText(
        find.widgetWithText(TextField, 'Meta field (optional)'), 'sensor');
    await tester.enterText(
        find.widgetWithText(TextField, 'Expire after seconds (optional)'),
        '86400');
    await shot(tester, '21-create-collection');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(client.collectionOptions[const Namespace('metrics', 'readings')], {
      'timeseries': {
        'timeField': 'ts',
        'metaField': 'sensor',
        'granularity': 'seconds',
      },
      'expireAfterSeconds': 86400,
    });
    expect(find.text('Collection readings created'), findsOneWidget);
    clearSnacks();

    // Rename it from the collection menu.
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename collection…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'New name'), 'r2');
    await tester.pump();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(client.data['metrics']!.keys, ['r2']);
    expect(find.text('Renamed readings to r2'), findsOneWidget);
    clearSnacks();

    // Back up to the database, add a capped collection, then drop it all.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create collection'));
    await tester.pumpAndSettle();
    expect(find.text('In metrics'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Collection name'), 'log');
    await tester.tap(find.text('Capped'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the capped size in bytes'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Size in bytes'), '1048576');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(client.collectionOptions[const Namespace('metrics', 'log')],
        {'capped': true, 'size': 1048576});
    clearSnacks();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drop database…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'metrics');
    await tester.pump();
    await tester.tap(find.text('Drop'));
    await tester.pumpAndSettle();
    expect(client.data.containsKey('metrics'), isFalse);
    expect(find.text('Database metrics dropped'), findsOneWidget);
  });

  testWidgets('schema tab', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '{ paid: true }');
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    expect(find.text('Analyze the schema'), findsOneWidget);
    await tester.tap(find.text('Analyze'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Analyzed 20 documents matching'), findsOneWidget);
    expect(client.pipelines.last.first, {
      r'$match': {'paid': true},
    });
    // notes is a long string on one document and null on the rest.
    await tester.scrollUntilVisible(find.text('notes'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Null 95%'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('customer'), -300,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('Show 3 nested fields').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 3 nested fields').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('address'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('address'), findsOneWidget);
    await shot(tester, '22-schema');

    // The analysis survives a trip to another tab.
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    expect(find.text('Analyze again'), findsOneWidget);
  });

  testWidgets('validation tab', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Validation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Validation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter rules to see'), findsOneWidget);

    final rules = find.byType(TextField).last;
    await tester.enterText(rules, '{ total: { \$gte: 80 } }');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('Passes validation'), findsOneWidget);
    expect(find.text('Fails validation'), findsOneWidget);
    await shot(tester, '23-validation');
    expect(find.textContaining('1035', findRichText: true), findsOneWidget);

    // Updating needs write mode.
    final update = find.widgetWithText(AccentButton, 'Update');
    expect(tester.widget<AccentButton>(update).onPressed, isNull);
    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Warning').last);
    await tester.pumpAndSettle();
    await tester.tap(update);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update').last);
    await tester.pumpAndSettle();
    expect(client.collMods.last.$2, {
      'validator': {
        'total': {r'$gte': 80},
      },
      'validationLevel': 'strict',
      'validationAction': 'warn',
    });
    expect(find.text('Validation updated'), findsOneWidget);
    // The tab reloads with the saved rules.
    expect(find.textContaining('80'), findsWidgets);

    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      contains(r'$jsonSchema'),
    );
  });

  testWidgets('index usage, hiding, builds and options', (tester) async {
    final client = FakeMongoClient(sampleData());
    const orders = Namespace('shop', 'orders');
    client.indexes[orders] = [
      {
        'v': 2,
        'key': {'customer.name': 1},
        'name': 'customer.name_1',
      },
    ];
    var building = true;
    client.onCommand = (db, cmd) {
      if (cmd['aggregate'] == 1 && building) {
        return {
          'cursor': {
            'firstBatch': [
              {
                'opid': 7,
                'command': {
                  'createIndexes': 'orders',
                  'indexes': [
                    {
                      'key': {'total': 1},
                      'name': 'total_1',
                    },
                  ],
                },
                'progress': {'done': 30, 'total': 40},
                'msg': 'Index Build: scanning collection 30/40 75%',
              },
            ],
          },
        };
      }
      return null;
    };
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indexes'));
    await tester.pumpAndSettle();
    expect(find.text('BUILDING'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.textContaining('Used 42 times'), findsOneWidget);
    expect(find.textContaining('Not used'), findsOneWidget);
    await shot(tester, '24-indexes');
    expect(client.commands.last.$2['pipeline'], isA<List<Object?>>());

    // The build finishes: polling stops and the list refreshes.
    building = false;
    client.indexes[orders]!.add({
      'v': 2,
      'key': {'total': 1},
      'name': 'total_1',
    });
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('BUILDING'), findsNothing);
    expect(find.text('total_1'), findsOneWidget);

    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Index actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide index'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(client.collMods.last.$2, {
      'index': {'name': 'customer.name_1', 'hidden': true},
    });
    expect(find.text('HIDDEN'), findsOneWidget);

    await tester.tap(find.text('Create Index'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Keys'), r'{ "$**": 1 }');
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextField, 'Wildcard projection (optional)'),
        '{ customer: 1 }');
    await tester.enterText(
        find.widgetWithText(TextField, 'Collation (optional)'),
        "{ locale: 'en', strength: 2 }");
    await tester.tap(find.text('Create Index').last);
    await tester.pumpAndSettle();
    final created = client.indexes[orders]!.last;
    expect(created['name'], r'$**_1');
    expect(created['wildcardProjection'], {'customer': 1});
    expect(created['collation'], {'locale': 'en', 'strength': 2});
  });

  testWidgets('server activity', (tester) async {
    final data = sampleData();
    data['shop']!['system.profile'] = [
      {
        'op': 'query',
        'ns': 'shop.orders',
        'millis': 412,
        'planSummary': 'COLLSCAN',
        'docsExamined': 40,
        'nreturned': 1,
        'ts': DateTime.utc(2026, 1, 2),
        'command': {'find': 'orders', 'filter': {'total': 99}},
      },
    ];
    final client = FakeMongoClient(data);
    var tick = 0;
    client.onCommand = (db, cmd) {
      if (cmd.containsKey('serverStatus')) {
        tick++;
        return {
          'opcounters': {'query': 100 + tick * 20, 'insert': tick * 4},
          'connections': {'current': 7, 'available': 800},
          'network': {'bytesIn': tick * 2048, 'bytesOut': tick * 4096},
          'mem': {'resident': 256},
          'localTime': DateTime.utc(2026).add(Duration(seconds: tick * 2)),
        };
      }
      if (cmd['aggregate'] == 1) {
        return {
          'cursor': {
            'firstBatch': [
              {
                'opid': 4242,
                'op': 'query',
                'ns': 'shop.orders',
                'client': '10.0.0.5:51234',
                'appName': 'reporting',
                'secs_running': 75,
                'planSummary': 'COLLSCAN',
                'command': {'find': 'orders', 'filter': {'x': 1}},
              },
            ],
          },
        };
      }
      if (cmd['profile'] == -1) return {'was': 1, 'slowms': 100};
      return null;
    };
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server activity'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Operations per second'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    await shot(tester, '25-activity');

    await tester.tap(find.text('Operations'));
    await tester.pumpAndSettle();
    expect(find.text('1m 15s'), findsOneWidget);
    expect(find.textContaining('reporting'), findsOneWidget);
    await tester.tap(find.byTooltip('Kill operation'));
    await tester.pumpAndSettle();
    expect(find.text('Turn on write mode to kill operations'), findsOneWidget);

    await tester.tap(find.text('Slow queries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a database'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('shop').last);
    await tester.pumpAndSettle();
    expect(find.text('412 ms'), findsOneWidget);
    expect(find.textContaining('Profiling operations slower than 100 ms'),
        findsOneWidget);
    await shot(tester, '25b-slow-queries');

    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('connection form', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore();
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New connection').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Atlas');
    await tester.tap(find.text('Form'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mongodb+srv'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Host name'), 'cluster0.ab.mongodb.net');
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Username / Password').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'app');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'p@ss');
    await tester.scrollUntilVisible(
        find.widgetWithText(TextFormField, 'App name'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'App name'), 'phone');
    await tester.pump();
    await shot(tester, '26-connection-form');
    expect(find.text('mongodb+srv://app:****@cluster0.ab.mongodb.net/?appName=phone'),
        findsOneWidget);

    // Back to the string: it holds what the form built.
    await tester.scrollUntilVisible(find.text('Connection string'), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Connection string'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Save'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.saved.single.uri,
        'mongodb+srv://app:p%40ss@cluster0.ab.mongodb.net/?appName=phone');
    expect(store.saved.single.name, 'Atlas');
  });

  testWidgets('favourites, groups, export and import of connections',
      (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(
            id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
        const ConnectionProfile(
            id: 'b',
            name: 'Prod',
            uri: 'mongodb+srv://app:s3cret@cluster0.ab.mongodb.net/'),
        const ConnectionProfile(
            id: 'c', name: 'Staging', uri: 'mongodb://stage:27017'),
      ];
    final files = FakeFiles(null);
    await pumpApp(tester, client, store, files: files);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add to favourites').at(1));
    await tester.pumpAndSettle();
    expect(find.text('Favourites'), findsOneWidget);
    expect(store.saved.firstWhere((p) => p.id == 'b').favorite, isTrue);

    await tester.tap(find.byTooltip('Connection actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Work');
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    await shot(tester, '27-connections-grouped');

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export connections…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Include passwords'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase'), 'correct horse');
    await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase again'), 'correct horse');
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pumpAndSettle();
    final file = String.fromCharCodes(
        files.written['mongomobile-connections.json']!);
    expect(file, contains('Compass Connections'));
    expect(file, isNot(contains('s3cret')));

    // Import into an empty app.
    final store2 = MemoryConnectionStore();
    final files2 = FakeFiles(TextSource('connections.json', file));
    await pumpApp(tester, client, store2, files: files2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import connections…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'correct horse');
    await tester.tap(find.text('Import'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pumpAndSettle();
    expect(find.text('Imported 3 connections'), findsOneWidget);
    expect(store2.saved.firstWhere((p) => p.id == 'b').uri,
        'mongodb+srv://app:s3cret@cluster0.ab.mongodb.net/');
    expect(store2.saved.firstWhere((p) => p.id == 'b').favorite, isTrue);
    expect(store2.saved.firstWhere((p) => p.id == 'c').group, 'Work');
  });

  testWidgets('export to a file and drop a collection', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    final written = <int>[];
    var closed = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.mongomobile.app/files'),
      (call) async {
        switch (call.method) {
          case 'createDocument':
            expect(call.arguments['name'], 'shop.orders.csv');
            return 1;
          case 'write':
            written.addAll(call.arguments['bytes'] as List<int>);
          case 'close':
            closed = true;
        }
        return null;
      },
    );
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export shop.orders'), findsOneWidget);
    expect(find.text('~40 documents'), findsOneWidget);
    await tester.tap(find.text('CSV'));
    await shot(tester, '16-export');
    await tester.tap(find.text('Export…'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    final csv = String.fromCharCodes(written);
    expect(csv.split('\r\n').first, startsWith('_id,orderNo,customer.name'));
    expect(csv.split('\r\n').where((l) => l.isNotEmpty).length, 41);
    expect(find.text('Exported 40 documents'), findsOneWidget);

    // Dropping needs write mode and the typed collection name.
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drop collection…'));
    await tester.pumpAndSettle();
    expect(find.text('Turn on write mode to drop collections'), findsOneWidget);
    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drop collection…'));
    await tester.pumpAndSettle();
    final drop = find.widgetWithText(FilledButton, 'Drop');
    expect(tester.widget<FilledButton>(drop).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, 'orders');
    await tester.pump();
    await shot(tester, '17-drop-collection');
    await tester.tap(drop);
    await tester.pumpAndSettle();
    expect(client.data['shop']!.containsKey('orders'), isFalse);
    expect(find.text('Collection orders dropped'), findsOneWidget);
    expect(find.text('Database'), findsOneWidget);
  });

  testWidgets('query options, history, explain and code export', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();

    // All options are there.
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    for (final label in ['Project', 'Sort', 'Collation', 'Hint', 'Skip', 'Limit', 'Max time ms']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    TextField field(String label) => tester.widget<TextField>(
          find.ancestor(of: find.text(label), matching: find.byType(TextField)));
    await tester.enterText(find.byType(TextField).first, '{ paid: true }');
    await tester.enterText(
        find.ancestor(of: find.text('Skip'), matching: find.byType(TextField)), '5');
    await tester.enterText(
        find.ancestor(of: find.text('Hint'), matching: find.byType(TextField)), 'paid_1');
    await shot(tester, '21-query-options');
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();
    expect(client.finds.last.skip, 5);
    expect(client.finds.last.hint, 'paid_1');
    expect(field('Skip').controller!.text, '5');

    // Saved to history; reset, then bring it back from history.
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(field('Skip').controller!.text, '');
    await tester.tap(find.byTooltip('Query history'));
    await tester.pumpAndSettle();
    await shot(tester, '22-history');
    expect(find.text('filter: { paid: true }'), findsOneWidget);
    await tester.tap(find.text('filter: { paid: true }'));
    await tester.pumpAndSettle();
    expect(field('Skip').controller!.text, '5');
    expect(client.finds.last.skip, 5);

    // Save as favourite.
    await tester.tap(find.byTooltip('Save as favourite'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Paid orders');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Query history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favourites'));
    await tester.pumpAndSettle();
    expect(find.text('Paid orders'), findsOneWidget);
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();

    // Explain.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain plan'));
    await tester.pumpAndSettle();
    await shot(tester, '23-explain');
    expect(find.text('Uses index paid_1.'), findsOneWidget);
    expect(find.text('IXSCAN'), findsOneWidget);
    expect(client.explained.last['skip'], 5);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Export to language.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export query to language'));
    await tester.pumpAndSettle();
    expect(find.textContaining('collection.find('), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Go'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(CodeExportSheet),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await shot(tester, '24-code');
    expect(find.textContaining('SetSkip(5)'), findsOneWidget);
  });

  testWidgets('aggregation builder, results, views', (tester) async {
    final client = FakeMongoClient(sampleData());
    final store = MemoryConnectionStore()
      ..saved = [
        const ConnectionProfile(id: 'a', name: 'Local dev', uri: 'mongodb://localhost'),
      ];
    await pumpApp(tester, client, store);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text('shop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('orders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aggregations'));
    await tester.pumpAndSettle();

    // Edit the default $match and preview its output.
    final stageField = find.descendant(
        of: find.byType(Card).first, matching: find.byType(TextField));
    await tester.enterText(stageField, '{ paid: true }');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Output preview'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.textContaining('Output: first 10 documents'), findsOneWidget);
    expect(client.pipelines.last.last, {r'$limit': 10});

    // Add a $limit stage through the picker.
    await tester.scrollUntilVisible(
      find.text('Add stage'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(AggregationsView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add stage'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'limit');
    await tester.pumpAndSettle();
    await tester.tap(find.text(r'$limit').last);
    await tester.pumpAndSettle();
    await shot(tester, '25-aggregation');
    expect(find.text('2 stages'), findsOneWidget);
    expect(find.text('Stage 2'), findsOneWidget);

    // Run: results page.
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    await shot(tester, '26-aggregation-results');
    expect(find.textContaining('1 – 20 ·'), findsOneWidget);
    expect(client.pipelines.last.take(2).toList(), [
      {
        r'$match': {'paid': true},
      },
      {r'$limit': 20},
    ]);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Text mode shows the whole pipeline.
    await tester.tap(find.byTooltip('Text'));
    await tester.pumpAndSettle();
    expect(find.textContaining(r'"$limit": 20'), findsOneWidget);
    await tester.tap(find.byTooltip('Stages'));
    await tester.pumpAndSettle();

    // Save it.
    await tester.tap(find.byTooltip('Pipeline actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Paid sample');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Paid sample'), findsOneWidget);

    // Create a view (needs write mode).
    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow writes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pipeline actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create view…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'paid_orders');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    final viewNs = const Namespace('shop', 'paid_orders');
    expect(client.collectionOptions[viewNs]!['viewOn'], 'orders');

    // Open the view and edit its pipeline.
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('paid_orders'), findsWidgets);
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit view pipeline…'));
    await tester.pumpAndSettle();
    expect(find.text('Edit view paid_orders'), findsOneWidget);
    expect(find.text('Stage 2'), findsOneWidget);
    await tester.tap(find.text('Update view'));
    await tester.pumpAndSettle();
    expect(client.collMods.last.$1, viewNs);
    expect(client.collMods.last.$2['viewOn'], 'orders');
    expect(find.text('View paid_orders updated'), findsOneWidget);
  });
}
