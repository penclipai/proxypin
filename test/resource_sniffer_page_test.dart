import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/l10n/app_localizations_en.dart';
import 'package:proxypin/l10n/app_localizations_zh.dart';
import 'package:proxypin/ui/toolbox/resource_sniffer_page.dart';

Map<String, dynamic> resource(int id, {String kind = 'video', String? name, String? host}) => {
      'id': '$id',
      'url': 'https://${host ?? 'media.example.com'}/${name ?? 'video-$id.mp4'}?signature=abc+$id&expires=2000000000',
      'fileName': name ?? 'video-$id.mp4',
      'kind': kind,
      'mimeType': switch (kind) { 'audio' => 'audio/mpeg', 'hls' => 'application/vnd.apple.mpegurl', _ => 'video/mp4' },
      'sizeBytes': id == 3 ? null : 1234567,
      'statusCode': 206,
      'host': host ?? 'media.example.com',
      'referer': 'https://watch.example.com/',
      'processName': 'Browser.exe',
      'firstSeen': '2026-10-02T03:04:05Z',
      'lastSeen': '2026-10-02T03:05:06Z',
      'hitCount': 3,
      'requestId': '$id-request',
      'matchReason': 'mime:video/mp4',
    };

class _FakeSniffer {
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> resources;
  Map<String, dynamic> config = {'enabled': true, 'includeImages': false, 'rules': []};
  int revision = 1;
  bool fail = false;
  Completer<Map<String, dynamic>>? heldQuery;
  Completer<Map<String, dynamic>>? heldMutation;

  _FakeSniffer(this.resources);

  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> arguments) async {
    calls.add((method, Map<String, dynamic>.from(arguments)));
    if (fail) throw StateError('Main window unavailable');
    switch (method) {
      case 'resourceSnifferQuery':
        if (heldQuery != null) return heldQuery!.future;
        if (arguments['knownRevision'] == revision) return {'revision': revision, 'unchanged': true};
        final filtered = _filtered(arguments);
        final offset = arguments['offset'] as int? ?? 0;
        final limit = arguments['limit'] as int? ?? 100;
        return {
          'revision': revision,
          'total': filtered.length,
          'resources': filtered.skip(offset).take(limit).toList(),
          'hosts': resources.map((r) => r['host']).toSet().toList(),
          'config': config,
        };
      case 'resourceSnifferSetEnabled':
        if (heldMutation != null) return heldMutation!.future;
        config = {...config, 'enabled': arguments['enabled']};
        revision++;
      case 'resourceSnifferClear':
        resources = [];
        revision++;
      case 'resourceSnifferUpdateConfig':
        config = {...config, ...Map<String, dynamic>.from(arguments['config'] as Map), 'enabled': config['enabled']};
        revision++;
      case 'resourceSnifferExport':
        return {'resources': _filtered(arguments)};
    }
    return {'revision': revision, 'config': config};
  }

  List<Map<String, dynamic>> _filtered(Map<String, dynamic> args) => resources.where((r) {
        if (args['kind'] != null && args['kind'] != 'all' && r['kind'] != args['kind']) return false;
        if (args['host'] != null && args['host'] != '' && r['host'] != args['host']) return false;
        if (args['keyword'] != null && !r['url'].toString().contains(args['keyword'].toString())) return false;
        if (args['ids'] is List && !(args['ids'] as List).contains(r['id'])) return false;
        return true;
      }).toList();

  List<Map<String, dynamic>> get queries =>
      calls.where((call) => call.$1 == 'resourceSnifferQuery').map((call) => call.$2).toList();
}

class _MemoryFilePicker extends FilePickerPlatform {
  final files = <String, Uint8List>{};

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    files[fileName] = bytes;
    return Uri.file('C:/exports/$fileName');
  }
}

Widget _wrap(_FakeSniffer server, {Key? boundaryKey, String? fontFamily, Locale locale = const Locale('en')}) =>
    RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        theme: ThemeData(fontFamily: fontFamily),
        localizationsDelegates: [const _TestLocalizations(), ...AppLocalizations.localizationsDelegates.skip(1)],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ResourceSnifferPage(command: server.call),
      ),
    );

class _TestLocalizations extends LocalizationsDelegate<AppLocalizations> {
  const _TestLocalizations();

  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(locale.languageCode == 'zh' ? AppLocalizationsZh() : AppLocalizationsEn());

  @override
  bool shouldReload(_TestLocalizations old) => false;
}

void _desktopSize(WidgetTester tester, {Size size = const Size(960, 720)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<String?> _loadDesktopFonts(WidgetTester tester) => tester.runAsync<String?>(() async {
      String? fontFamily;
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('SnifferPreviewFont')..addFont(font.readAsBytes().then(ByteData.sublistView));
        await loader.load();
        fontFamily = 'SnifferPreviewFont';
      }
      final icons = File('C:/Users/EDY/develop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (await icons.exists()) {
        await (FontLoader('MaterialIcons')..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
      }
      return fontFamily;
    });

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) => tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });

void main() {
  testWidgets('queries immediately, polls revision, updates and cancels polling on disposal', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    expect(server.queries.single['limit'], 100);
    expect(find.text('video-1.mp4'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(server.queries.last['knownRevision'], 1);
    server.resources = [resource(2, name: 'updated.mp4')];
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('updated.mp4'), findsOneWidget);
    expect(find.text('video-1.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final count = server.queries.length;
    await tester.pump(const Duration(seconds: 3));
    expect(server.queries.length, count);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not overlap pending requests and discards stale filter results', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1), resource(2, name: 'wanted.mp4')]);
    final pending = Completer<Map<String, dynamic>>();
    server.heldQuery = pending;
    await tester.pumpWidget(_wrap(server));
    await tester.pump(const Duration(seconds: 2));
    expect(server.queries.length, 1);
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'wanted');
    await tester.pump(const Duration(milliseconds: 300));
    server.heldQuery = null;
    pending.complete({
      'revision': 1,
      'resources': [resource(1)],
      'total': 1,
      'config': server.config,
      'hosts': []
    });
    await tester.pump();
    await tester.pump();
    expect(server.queries.length, 2);
    expect(server.queries.last['keyword'], 'wanted');
    expect(find.text('wanted.mp4'), findsOneWidget);
    expect(find.text('video-1.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('filters reset page and force full queries; page controls use 100 entries', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer(List.generate(201, (id) => resource(id)));
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-next')));
    await tester.pump();
    expect(server.queries.last['offset'], 100);
    expect(server.queries.last.containsKey('knownRevision'), false);
    expect(find.text('video-100.mp4'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'video-200');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(server.queries.last['offset'], 0);
    expect(server.queries.last['keyword'], 'video-200');
    expect(find.text('video-200.mp4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('category and domain filters are sent to the main window', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1), resource(2, kind: 'audio', host: 'audio.example.com')]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Audio').last);
    await tester.pumpAndSettle();
    expect(server.queries.last['kind'], 'audio');
    await tester.tap(find.byKey(const Key('sniffer-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('audio.example.com').last);
    await tester.pumpAndSettle();
    expect(server.queries.last['host'], 'audio.example.com');
    expect(find.text('video-1.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('pause and clear command the main window without disposing the collection service', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-toggle')));
    await tester.pump();
    await tester.pump();
    expect(server.config['enabled'], false);
    expect(find.text('Recognition paused'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sniffer-select-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-clear')));
    await tester.pump();
    await tester.pump();
    expect(find.text('video-1.mp4'), findsNothing);
    expect(find.text('Selected: 0'), findsOneWidget);
    expect(find.text(' ·  All: 0'), findsOneWidget);
    expect(server.calls.any((call) => call.$1 == 'resourceSnifferClear'), true);
    expect(server.calls.every((call) => call.$1.startsWith('resourceSniffer')), true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pause and resume immediately apply returned state while an old poll is pending', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    final pending = Completer<Map<String, dynamic>>();
    final oldConfig = Map<String, dynamic>.from(server.config);
    server.heldQuery = pending;
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('sniffer-toggle')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sniffer-toggle')));
    await tester.pump();
    await tester.pump();
    final toggles = server.calls.where((call) => call.$1 == 'resourceSnifferSetEnabled').toList();
    expect(toggles.map((call) => call.$2['enabled']), [false, true]);
    expect(find.text('Pause'), findsOneWidget);
    server.heldQuery = null;
    pending.complete({'revision': 1, 'config': oldConfig, 'resources': [], 'total': 0, 'hosts': []});
    await tester.pump();
    await tester.pump();
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('video-1.mp4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear immediately empties the list and prevents a pending old poll from restoring rows', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    final pending = Completer<Map<String, dynamic>>();
    server.heldQuery = pending;
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('sniffer-clear')));
    await tester.pump();
    expect(find.text('video-1.mp4'), findsNothing);
    expect(find.text(' ·  All: 0'), findsOneWidget);
    server.heldQuery = null;
    pending.complete({
      'revision': 1,
      'config': server.config,
      'resources': [resource(1)],
      'total': 1,
      'hosts': []
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('video-1.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a filter query started during pending mutation cannot restore its earlier enabled state',
      (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    final oldConfig = Map<String, dynamic>.from(server.config);
    final mutation = Completer<Map<String, dynamic>>();
    server.heldMutation = mutation;
    await tester.tap(find.byKey(const Key('sniffer-toggle')));
    await tester.pump();
    final oldFilterQuery = Completer<Map<String, dynamic>>();
    server.heldQuery = oldFilterQuery;
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'video-1');
    await tester.pump(const Duration(milliseconds: 300));
    expect(server.queries.last['keyword'], 'video-1');
    server.config = {...server.config, 'enabled': false};
    server.revision++;
    mutation.complete({'revision': server.revision, 'config': server.config});
    await tester.pump();
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);

    // Keep the fresh reload pending, so an intermediate stale overwrite would
    // be visible instead of immediately being corrected by the next query.
    final latestFilterQuery = Completer<Map<String, dynamic>>();
    server.heldQuery = latestFilterQuery;
    oldFilterQuery
        .complete({'revision': 1, 'config': oldConfig, 'resources': server.resources, 'total': 1, 'hosts': []});
    await tester.pump();
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    expect(server.queries.last['keyword'], 'video-1');
    expect(server.queries.last.containsKey('knownRevision'), false);
    latestFilterQuery.complete(
        {'revision': server.revision, 'config': server.config, 'resources': server.resources, 'total': 1, 'hosts': []});
    await tester.pump();
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('video-1.mp4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection survives polling and exports exact selected URLs and metadata', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1), resource(2)]);
    final picker = _MemoryFilePicker();
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-select-1')));
    await tester.pump();
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byKey(const Key('sniffer-select-1'))).value, true);
    await tester.tap(find.byKey(const Key('sniffer-copy')));
    await tester.pump();
    await tester.pump();
    expect(clipboard, server.resources.first['url']);
    await tester.tap(find.byKey(const Key('sniffer-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export TXT'));
    await tester.pumpAndSettle();
    expect(utf8.decode(picker.files['resources.txt']!), '${server.resources.first['url']}\n');
    await tester.tap(find.byKey(const Key('sniffer-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export JSON'));
    await tester.pumpAndSettle();
    final json = jsonDecode(utf8.decode(picker.files['resources.json']!)) as List;
    expect(json.single, server.resources.first);
    expect(
        server.calls
            .where((call) => call.$1 == 'resourceSnifferExport')
            .every((call) => (call.$2['ids'] as List).single == '1'),
        true);
    ScaffoldMessenger.of(tester.element(find.byType(ResourceSnifferPage))).removeCurrentSnackBar();
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-clear-selection')));
    await tester.pump();
    expect(find.text('Selected: 0'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'video-2');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-copy')));
    await tester.pump();
    await tester.pump();
    expect(clipboard, server.resources.last['url']);
    final filteredExport = server.calls.lastWhere((call) => call.$1 == 'resourceSnifferExport').$2;
    expect(filteredExport['keyword'], 'video-2');
    expect(filteredExport.containsKey('ids'), false);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('details show full signed URL, status, process and recognition without networking', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    server.resources.single['matchReason'] = 'custom:urlRegex:https://cdn.example.com/.+';
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.text('video-1.mp4'));
    await tester.pumpAndSettle();
    expect(find.text(server.resources.single['url'] as String), findsOneWidget);
    expect(find.text('206'), findsOneWidget);
    expect(find.text('Browser.exe'), findsOneWidget);
    expect(find.text('Custom recognition rules · URL regular expression: https://cdn.example.com/.+'), findsOneWidget);
    expect(server.calls.every((call) => call.$1 == 'resourceSnifferQuery'), true);
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('Copy links').last);
    await tester.pump();
    expect(clipboard, server.resources.single['url']);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid regex blocks saving and image setting and ordered rules persist', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([]);
    server.config['rules'] = [
      {'id': 'first', 'type': 'urlRegex', 'pattern': '[', 'kind': 'hls', 'enabled': true},
      {'id': 'second', 'type': 'extension', 'pattern': 'mp4', 'kind': 'video', 'enabled': true},
    ];
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sniffer-save-settings')));
    await tester.pump();
    expect(find.byKey(const Key('sniffer-rule-error')), findsOneWidget);
    expect(server.calls.where((call) => call.$1 == 'resourceSnifferUpdateConfig'), isEmpty);
    await tester.enterText(find.byKey(const ValueKey('sniffer-rule-pattern-first')), r'\.m3u8');
    await tester.tap(find.byKey(const Key('sniffer-images')));
    await tester.pump();
    await tester.tap(find.byTooltip('Move down').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-save-settings')));
    await tester.pumpAndSettle();
    expect(server.config['includeImages'], true);
    expect((server.config['rules'] as List).first['id'], 'second');
    expect((server.config['rules'] as List).last['pattern'], r'\.m3u8');
    expect(find.byKey(const Key('sniffer-rule-error')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection failure is visible and retry reconnects', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)])..fail = true;
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    expect(find.textContaining('Unable to communicate with the main window'), findsOneWidget);
    server.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('video-1.mp4'), findsOneWidget);
    expect(find.textContaining('Unable to communicate with the main window'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings save preserves another window pause and is not overwritten by a pending poll', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-settings')));
    await tester.pumpAndSettle();
    // The main-window service is paused by another sniffer window.
    server.config = {...server.config, 'enabled': false};
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final oldConfig = Map<String, dynamic>.from(server.config);
    final pending = Completer<Map<String, dynamic>>();
    server.heldQuery = pending;
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('sniffer-images')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-save-settings')));
    await tester.pumpAndSettle();
    expect(server.config['enabled'], false);
    expect(server.config['includeImages'], true);
    expect(find.text('Resume'), findsOneWidget);
    server.heldQuery = null;
    pending.complete({'revision': 2, 'config': oldConfig, 'resources': [], 'total': 0, 'hosts': []});
    await tester.pump();
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('video-1.mp4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sniffer-settings')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('sniffer-images'))).value, true);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving recognition settings before the next poll preserves a shared pause', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer([resource(1)]);
    await tester.pumpWidget(_wrap(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-settings')));
    await tester.pumpAndSettle();
    // A second window pauses the service while this child still shows Pause.
    server.config = {...server.config, 'enabled': false};
    server.revision++;
    await tester.tap(find.byKey(const Key('sniffer-images')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-save-settings')));
    await tester.pumpAndSettle();
    final submitted = server.calls.singleWhere((call) => call.$1 == 'resourceSnifferUpdateConfig').$2['config'] as Map;
    expect(submitted.containsKey('enabled'), false);
    expect(server.config['enabled'], false);
    expect(server.config['includeImages'], true);
    expect(find.text('Resume'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('populated desktop layout renders virtual rows without overflow and emits preview', (tester) async {
    _desktopSize(tester, size: const Size(1100, 760));
    final server = _FakeSniffer([
      resource(1, name: 'concert-live-1080p.mp4'),
      resource(2, kind: 'audio', name: 'interview-track.mp3', host: 'audio.example.com'),
      resource(3, kind: 'hls', name: 'master.m3u8'),
      resource(4,
          name: 'a-long-resource-name-that-retains-full-identity-in-the-details.mp4',
          host: 'very-long-cdn-hostname.assets.example.com'),
      ...List.generate(150, (id) => resource(id + 5)),
    ]);
    final boundaryKey = GlobalKey();
    String? fontFamily;
    await tester.runAsync(() async {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('SnifferPreviewFont')..addFont(font.readAsBytes().then(ByteData.sublistView));
        await loader.load();
        fontFamily = 'SnifferPreviewFont';
      }
      final icons = File('C:/Users/EDY/develop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (await icons.exists()) {
        await (FontLoader('MaterialIcons')..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
      }
    });
    await tester
        .pumpWidget(_wrap(server, boundaryKey: boundaryKey, fontFamily: fontFamily, locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('concert-live-1080p.mp4'), findsOneWidget);
    expect(find.text('音频'), findsOneWidget);
    expect(find.text('HLS'), findsOneWidget);
    expect(find.text('未知'), findsOneWidget);
    expect(find.text('video-104.mp4'), findsNothing); // Rows outside viewport are not built.
    expect(tester.takeException(), isNull);
    final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/resource-sniffer-preview.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resource list scrolls with the wheel while its header stays fixed and rows remain virtual',
      (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer(List.generate(201, (id) => resource(id)));
    await tester.pumpWidget(_wrap(server));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byKey(const Key('sniffer-resource-list')));
    final vertical = list.controller!;
    final header = tester.getRect(find.byKey(const Key('sniffer-table-header')));
    expect(list.semanticChildCount, 100);
    expect(vertical.positions.length, 1);
    expect(find.byKey(const Key('sniffer-resource-99')), findsNothing);
    expect(find.byKey(const Key('sniffer-resource-100')), findsNothing);

    await tester.sendEventToBinding(PointerScrollEvent(
      position: tester.getCenter(find.byKey(const Key('sniffer-vertical-scrollbar'))),
      scrollDelta: const Offset(0, 640),
    ));
    await tester.pumpAndSettle();
    expect(vertical.offset, greaterThan(0));
    expect(tester.getRect(find.byKey(const Key('sniffer-table-header'))), header);
    expect(find.byKey(const Key('sniffer-resource-0')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live row reorder retains element, checkbox focus and accessibility node identity', (tester) async {
    _desktopSize(tester);
    final semantics = tester.ensureSemantics();
    try {
      final server = _FakeSniffer([resource(1), resource(2), resource(3)]);
      await tester.pumpWidget(_wrap(server));
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('sniffer-resource-1'));
      final checkbox = find.byKey(const Key('sniffer-select-1'));
      final rowElement = tester.element(row);
      final checkboxElement = tester.element(checkbox);
      final checkboxPaint = find.descendant(of: checkbox, matching: find.byType(CustomPaint)).last;
      final focus = Focus.of(tester.element(checkboxPaint));
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, true);
      final nodeId = tester.getSemantics(checkbox).id;

      // Capture order changes during polling as new traffic arrives. The row
      // must move as one keyed subtree, preserving its focus and AX identity.
      server.resources = [resource(3), resource(1), resource(2)];
      server.revision++;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.element(row), same(rowElement));
      expect(tester.element(checkbox), same(checkboxElement));
      expect(Focus.of(tester.element(checkboxPaint)), same(focus));
      expect(focus.hasFocus, true);
      expect(tester.getSemantics(checkbox).id, nodeId);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  for (final size in [
    const Size(800, 700),
    const Size(960, 720),
    const Size(1100, 800),
    const Size(1280, 800),
    const Size(1440, 900),
  ]) {
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      testWidgets(
          'resource table fits ${size.width.toInt()}px ${locale.languageCode} window without horizontal scrolling',
          (tester) async {
        _desktopSize(tester, size: size);
        const longName =
            'a-very-long-resource-name-with-signature-and-full-original-identity-concert-live-3840x2160.mp4';
        const longHost = 'very-long-media-cdn-hostname.with-many-subdomains.streaming.assets.example.com';
        final server = _FakeSniffer([
          {
            ...resource(0, name: longName, host: longHost),
            'mimeType': 'video/mp4; codecs="avc1.640032,mp4a.40.2"',
            'preview': {'width': 3840, 'height': 2160, 'durationMs': 3600000},
          },
          ...List.generate(99, (id) => resource(id + 1)),
        ]);
        final capture = size.width == 800 || size.width == 1280;
        final boundaryKey = GlobalKey();
        final fontFamily = capture ? await _loadDesktopFonts(tester) : null;
        await tester.pumpWidget(_wrap(server, locale: locale, boundaryKey: boundaryKey, fontFamily: fontFamily));
        await tester.pumpAndSettle();

        final header = tester.getRect(find.byKey(const Key('sniffer-table-header')));
        final firstRow = tester.getRect(find.byKey(const Key('sniffer-resource-0')));
        final scrollbar = tester.getRect(find.byKey(const Key('sniffer-vertical-scrollbar')));
        expect(header.left, greaterThanOrEqualTo(16));
        expect(header.right, lessThanOrEqualTo(size.width - 16));
        expect(firstRow.left, header.left);
        expect(firstRow.right, lessThanOrEqualTo(header.right));
        expect(header.right - firstRow.right, lessThanOrEqualTo(12));
        expect(tester.getCenter(find.byKey(const Key('sniffer-select-0'))).dx,
            tester.getCenter(find.byKey(const Key('sniffer-select-page'))).dx);
        expect(scrollbar.right, size.width - 16);
        expect(
            find.byWidgetPredicate((widget) =>
                (widget is ScrollView && widget.scrollDirection == Axis.horizontal) ||
                (widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal)),
            findsNothing);
        expect(find.byKey(const Key('sniffer-horizontal-scrollbar')), findsNothing);
        expect(find.text(longName), findsOneWidget);
        expect(find.byKey(const Key('sniffer-preview-0')), findsOneWidget);
        expect(find.byKey(const Key('sniffer-copy-0')).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture) {
          await _capture(
              tester, boundaryKey, 'build/review/resource-sniffer-${size.width.toInt()}-${locale.languageCode}.png');
        }

        // The compact layout still exposes the full resource identity through
        // details rather than dropping metadata to make the row fit.
        await tester.tap(find.text(longName));
        await tester.pumpAndSettle();
        expect(find.text(server.resources.first['url'] as String), findsOneWidget);
        expect(find.text('video/mp4; codecs="avc1.640032,mp4a.40.2"'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('resizing an open resource window keeps selection and scroll position without horizontal scrolling',
      (tester) async {
    _desktopSize(tester, size: const Size(1440, 900));
    final server = _FakeSniffer(List.generate(100, (id) => resource(id)));
    await tester.pumpWidget(_wrap(server));
    await tester.pumpAndSettle();
    final pageElement = tester.element(find.byType(ResourceSnifferPage));
    await tester.tap(find.byKey(const Key('sniffer-select-0')));
    await tester.pump();
    final list = tester.widget<ListView>(find.byKey(const Key('sniffer-resource-list')));
    final controller = list.controller!;
    await tester.drag(find.byKey(const Key('sniffer-resource-list')), const Offset(0, -320));
    await tester.pumpAndSettle();
    final offset = controller.offset;
    expect(offset, greaterThan(0));

    for (final size in [const Size(800, 700), const Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(ResourceSnifferPage)), same(pageElement));
      expect(tester.widget<ListView>(find.byKey(const Key('sniffer-resource-list'))).controller, same(controller));
      expect(controller.offset, closeTo(offset, 0.001));
      expect(find.text('Selected: 1'), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('sniffer-table-header'))).right, lessThanOrEqualTo(size.width - 16));
      expect(tester.getRect(find.byKey(const Key('sniffer-vertical-scrollbar'))).right, size.width - 16);
      expect(
          find.byWidgetPredicate((widget) =>
              (widget is ScrollView && widget.scrollDirection == Axis.horizontal) ||
              (widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal)),
          findsNothing);
      expect(tester.takeException(), isNull);
    }
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byKey(const Key('sniffer-select-0'))).value, true);
    expect(server.calls.every((call) => call.$1 == 'resourceSnifferQuery'), true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('visible right scrollbar stays draggable without horizontal scrolling', (tester) async {
    _desktopSize(tester);
    final server = _FakeSniffer(List.generate(100, (id) => resource(id)));
    await tester.pumpWidget(_wrap(server));
    await tester.pumpAndSettle();
    final barFinder = find.byKey(const Key('sniffer-vertical-scrollbar'));
    final bar = tester.widget<Scrollbar>(barFinder);
    final original = tester.getRect(barFinder);
    final header = tester.getRect(find.byKey(const Key('sniffer-table-header')));
    expect(bar.thumbVisibility, true);
    expect(bar.trackVisibility, true);
    expect(bar.interactive, true);
    expect(bar.scrollbarOrientation, ScrollbarOrientation.right);
    expect(original.right, 944); // The visible viewport ends at the page's 16px margin.

    await tester.drag(find.byKey(const Key('sniffer-resource-list')), const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(bar.controller!.offset, 0);
    expect(tester.getRect(find.byKey(const Key('sniffer-table-header'))), header);
    expect(tester.getRect(barFinder), original);
    expect(
        find.byWidgetPredicate((widget) =>
            (widget is ScrollView && widget.scrollDirection == Axis.horizontal) ||
            (widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal)),
        findsNothing);

    // The right thumb remains visible and usable after an idle interval, even
    // when a horizontal gesture was made over the resource list.
    await tester.pump(const Duration(seconds: 3));
    await tester.dragFrom(Offset(original.right - 5, original.top + 16), const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(bar.controller!.offset, greaterThan(1000));
    expect(tester.getRect(barFinder), original);
    expect(tester.getRect(find.byKey(const Key('sniffer-table-header'))), header);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
