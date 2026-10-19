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
import 'package:mongomobile/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> pumpApp(WidgetTester tester, FakeMongoClient client,
    MemoryConnectionStore store, {AppSettings settings = const AppSettings()}) async {
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
      ],
      retry: (_, _) => null,
      child: RepaintBoundary(key: _boundary, child: const MongoMobileApp()),
    ),
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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
    await tester.pageBack();
    await tester.pumpAndSettle();

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
}
