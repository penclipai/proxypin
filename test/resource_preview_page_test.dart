import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/l10n/app_localizations_en.dart';
import 'package:proxypin/l10n/app_localizations_zh.dart';
import 'package:proxypin/ui/toolbox/resource_sniffer_page.dart';

Map<String, dynamic> _resource(String id, {String kind = 'video', String method = 'GET'}) => {
      'id': id,
      'fileName': 'media-$id.mp4',
      'url': 'https://media.example.com/media-$id.mp4?signature=$id',
      'kind': kind,
      'method': method,
      'host': 'media.example.com',
      'mimeType': 'video/mp4',
      'sizeBytes': 1024,
      'statusCode': 200,
      'hitCount': 1,
      'contentRevision': 0,
    };

class _PreviewServer {
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> resources;
  int revision = 1;
  int collectionGeneration = 0;
  Map<String, dynamic> preview = {};
  Completer<Map<String, dynamic>>? pending;
  Completer<Map<String, dynamic>>? pendingCancellation;

  _PreviewServer(this.resources);

  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> arguments) async {
    calls.add((method, Map<String, dynamic>.from(arguments)));
    switch (method) {
      case 'resourceSnifferPreview':
        if (pending != null) return pending!.future;
        final resource = resources.firstWhere((entry) => entry['id'] == arguments['id']);
        return {'preview': preview, 'contentRevision': resource['contentRevision']};
      case 'resourceSnifferCancelPreview':
        if (pendingCancellation != null) return pendingCancellation!.future;
        return {'cancelled': true};
      case 'resourceSnifferClear':
        resources = [];
        revision++;
        collectionGeneration++;
        return {'revision': revision};
      case 'resourceSnifferQuery':
        if (arguments['knownRevision'] == revision) return {'unchanged': true};
        final keyword = arguments['keyword']?.toString() ?? '';
        final filtered = resources.where((r) => r['fileName'].toString().contains(keyword)).toList();
        return {
          'revision': revision,
          'collectionGeneration': collectionGeneration,
          'config': {'enabled': true, 'rules': [], 'includeImages': false},
          'hosts': ['media.example.com'],
          'total': filtered.length,
          'resources': filtered.skip(arguments['offset'] as int? ?? 0).take(100).toList(),
        };
      default:
        throw StateError('Unexpected command: $method');
    }
  }

  int count(String method) => calls.where((call) => call.$1 == method).length;
}

class _PreviewLocalizations extends LocalizationsDelegate<AppLocalizations> {
  const _PreviewLocalizations();

  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(locale.languageCode == 'zh' ? AppLocalizationsZh() : AppLocalizationsEn());

  @override
  bool shouldReload(_PreviewLocalizations old) => false;
}

Widget _page(_PreviewServer server, {Widget? home, Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: [const _PreviewLocalizations(), ...AppLocalizations.localizationsDelegates.skip(1)],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home ?? ResourceSnifferPage(command: server.call),
    );

void _size(WidgetTester tester, {Size size = const Size(1100, 760)}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // Flutter verifies this debug setting before the package:test tearDown hooks.
  debugDefaultTargetPlatformOverride = null;
}

List<MethodCall> _nativeWindowCalls(WidgetTester tester) {
  const channel = MethodChannel('window_manager');
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  return calls;
}

Future<void> _nativeClose(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'window_manager',
    const StandardMethodCodec().encodeMethodCall(const MethodCall('onEvent', {'eventName': 'close'})),
    null,
  );
}

void main() {
  late String png;
  Map<String, dynamic> media() => {
        'imageBase64': png,
        'width': 1920,
        'height': 1080,
        'durationMs': 123000,
        'codec': 'H.264',
        'frameRate': 29.97,
        'bitrate': 3500000,
        'container': 'MP4',
      };

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xFFFF0000), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    png = base64Encode(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });

  testWidgets('opening, polling, filtering and inspecting details never request a preview', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1'), _resource('2')]);
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'media-1');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.text('media-1.mp4'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-detail-1')), findsOneWidget);
    expect(server.count('resourceSnifferPreview'), 0);
    expect(find.byType(Image), findsNothing);
    await _close(tester);
  });

  testWidgets('click loads one preview and displays thumbnail and metadata in list and details', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1'), _resource('2')]);
    final pending = Completer<Map<String, dynamic>>();
    server.pending = pending;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    expect(server.count('resourceSnifferPreview'), 1);
    expect(server.calls.last.$2['id'], '1');
    expect(server.calls.last.$2['clientId'], isA<String>());
    expect(tester.widget<IconButton>(find.byKey(const Key('sniffer-preview-2'))).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete({'preview': media()});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsOneWidget);
    expect(find.text('1920 × 1080'), findsOneWidget);
    expect(find.text('02:03'), findsOneWidget);

    // A metadata-only poll must retain the local PNG and richer result.
    server.resources.first['preview'] = {'width': 320, 'height': 240};
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsOneWidget);
    expect(find.text('1920 × 1080'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sniffer-resource-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-image-1')), findsOneWidget);
    expect(find.text('H.264'), findsOneWidget);
    expect(find.text('29.97 fps'), findsOneWidget);
    expect(find.text('3.50 Mbps'), findsOneWidget);
    expect(find.text('MP4'), findsOneWidget);
    expect(server.count('resourceSnifferPreview'), 1);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('content changes clear both the list frame and an already open detail preview', (tester) async {
    _size(tester);
    final server = _PreviewServer([
      {
        ..._resource('1'),
        'preview': {'width': 1920, 'height': 1080, 'codec': 'H.264'}
      }
    ])
      ..preview = media();
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sniffer-resource-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-image-1')), findsOneWidget);
    expect(find.text('H.264'), findsOneWidget);

    server.resources = [
      {..._resource('1', kind: 'audio'), 'mimeType': 'audio/mpeg', 'contentRevision': 1}
    ];
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsNothing);
    expect(find.byKey(const Key('sniffer-preview-image-1')), findsNothing);
    expect(find.text('H.264'), findsNothing);
    expect(find.text('1920 × 1080'), findsNothing);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('audio/mpeg')), findsOneWidget);
    expect(server.count('resourceSnifferPreview'), 1);

    server.preview = {'type': 'audio', 'codec': 'MP3', 'durationMs': 5000};
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pumpAndSettle();
    expect(find.text('MP3'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(server.count('resourceSnifferPreview'), 2);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('a content update cancels the owned preview and rejects its delayed result', (tester) async {
    _size(tester);
    final pending = Completer<Map<String, dynamic>>();
    final server = _PreviewServer([_resource('1')])..pending = pending;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    server.resources = [
      {..._resource('1'), 'contentRevision': 1, 'sizeBytes': 2048}
    ];
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(server.count('resourceSnifferCancelPreview'), 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    pending.complete({'preview': media(), 'contentRevision': 0});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsNothing);
    expect(find.text('1920 × 1080'), findsNothing);
    expect(server.count('resourceSnifferPreview'), 1);

    server.pending = null;
    server.preview = {...media(), 'width': 640, 'height': 360};
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pumpAndSettle();
    expect(find.text('640 × 360'), findsOneWidget);
    expect(server.count('resourceSnifferPreview'), 2);
    await _close(tester);
  });

  testWidgets('a newer preview reply reloads row metadata without installing a mismatched frame', (tester) async {
    _size(tester);
    final pending = Completer<Map<String, dynamic>>();
    final server = _PreviewServer([_resource('1')])..pending = pending;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    // The service sees the capture before this child's next metadata poll.
    server.resources = [
      {..._resource('1'), 'contentRevision': 1, 'mimeType': 'video/webm'}
    ];
    server.revision++;
    pending.complete({'preview': media(), 'contentRevision': 1});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsNothing);
    expect(find.text('video/webm'), findsOneWidget);
    expect(server.count('resourceSnifferPreview'), 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _close(tester);
  });

  testWidgets('an off-page cached preview is invalidated when its changed resource returns', (tester) async {
    _size(tester);
    final server = _PreviewServer(List.generate(101, (index) => _resource('${index + 1}')))..preview = media();
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sniffer-next')));
    await tester.pumpAndSettle();
    server.resources[0] = {..._resource('1'), 'contentRevision': 1};
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-previous')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsNothing);
    expect(find.text('1920 × 1080'), findsNothing);
    expect(server.count('resourceSnifferPreview'), 1);
    await _close(tester);
  });

  testWidgets('preview failures are visible and explicit retry can succeed', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    final failure = Completer<Map<String, dynamic>>();
    server.pending = failure;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-resource-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pump();
    failure.complete({'error': 'Unsupported media codec', 'code': 'decodeFailed'});
    await tester.pumpAndSettle();
    expect(find.textContaining(AppLocalizationsEn().resourceSnifferPreviewDecodeError), findsOneWidget);
    expect(find.textContaining('Unsupported media codec'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    server.pending = null;
    server.preview = media();
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-image-1')), findsOneWidget);
    expect(find.byKey(const Key('sniffer-preview-error-1')), findsNothing);
    expect(server.count('resourceSnifferPreview'), 2);
    final requests = server.calls.where((call) => call.$1 == 'resourceSnifferPreview').toList();
    expect(requests.first.$2['clientId'], requests.last.$2['clientId']);
    await _close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear cancels the active preview and a late result cannot restore rows or images', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    server.pending = pending;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-clear')));
    await tester.pump();
    await tester.pump();
    expect(server.count('resourceSnifferCancelPreview'), 1);
    expect(server.calls.firstWhere((call) => call.$1 == 'resourceSnifferCancelPreview').$2,
        server.calls.firstWhere((call) => call.$1 == 'resourceSnifferPreview').$2);
    pending.complete({'preview': media()});
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const Key('sniffer-resource-1')), findsNothing);
    server.resources = [_resource('1')];
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsNothing);
    expect(find.text('1920 × 1080'), findsNothing);
    await _close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown preview failures do not display exception URLs or authentication data', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    server.pending = pending;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.text('media-1.mp4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pump();
    pending.completeError(StateError('https://secret.example.com/video.mp4?token=private Authorization: secret'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('sniffer-preview-error-1'))).data,
        AppLocalizationsEn().resourceSnifferPreviewFailed);
    expect(find.textContaining('secret.example.com'), findsNothing);
    expect(find.textContaining('Authorization'), findsNothing);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('failure diagnostics use localized safe labels and preserve the resource name', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    server.pending = pending;
    final l = AppLocalizationsZh();
    await tester.pumpWidget(_page(server, locale: const Locale('zh')));
    await tester.pump();
    await tester.tap(find.text('media-1.mp4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pump();
    pending.complete({
      'error': 'Unreadable media at https://secret.example.com/video.mp4?token=private',
      'code': 'invalidMediaHeader',
      'diagnostics': {
        'stage': 'sourceOpen',
        'httpStatus': 403,
        'nativeHRESULT': '0xc00d36c4',
        'mediaHeader': 'unrecognizedMp4',
        'url': 'https://secret.example.com/video.mp4?token=private',
        'authorization': 'Bearer secret',
      },
    });
    await tester.pumpAndSettle();
    expect(find.textContaining(l.resourceSnifferPreviewInvalidMediaHeader), findsOneWidget);
    expect(find.text(l.resourceSnifferPreviewDiagnosticStage), findsOneWidget);
    expect(find.text(l.resourceSnifferPreviewStageSource), findsOneWidget);
    expect(find.text(l.resourceSnifferPreviewDiagnosticHttpStatus), findsOneWidget);
    expect(find.text('403'), findsOneWidget);
    expect(find.text(l.resourceSnifferPreviewDiagnosticNativeCode), findsOneWidget);
    expect(find.text('0xC00D36C4'), findsOneWidget);
    expect(find.text('media-1.mp4'), findsNWidgets(2));
    expect(find.textContaining('secret.example.com'), findsNothing);
    expect(find.textContaining('Bearer secret'), findsNothing);
    await tester.tap(find.text(l.close));
    await tester.pumpAndSettle();
    final entry = tester.widget<IconButton>(find.byKey(const Key('sniffer-preview-1')));
    expect(entry.tooltip, '${l.resourceSnifferRetry}: ${l.resourceSnifferPreviewInvalidMediaHeader}');
    expect(entry.tooltip, isNot(contains('0xC00D36C4')));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('all diagnostic stages and specific media failures map to localizations', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    final l = AppLocalizationsEn();
    final stages = {
      'resourceRequest': l.resourceSnifferPreviewStageRequest,
      'resourceRead': l.resourceSnifferPreviewStageRead,
      'manifestParse': l.resourceSnifferPreviewStageManifest,
      'imageDecode': l.resourceSnifferPreviewStageImage,
      'mediaDecode': l.resourceSnifferPreviewStageMedia,
      'sourceOpen': l.resourceSnifferPreviewStageSource,
      'streamType': l.resourceSnifferPreviewStageStream,
      'firstFrame': l.resourceSnifferPreviewStageFrame,
    };
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.text('media-1.mp4'));
    await tester.pumpAndSettle();
    for (final stage in stages.entries) {
      final pending = Completer<Map<String, dynamic>>();
      server.pending = pending;
      await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
      await tester.pump();
      pending.complete({
        'error': 'Private decoder error detail',
        'code': stage.key == 'firstFrame' ? 'protectedMedia' : 'codecUnavailable',
        'diagnostics': {'stage': stage.key},
      });
      await tester.pumpAndSettle();
      expect(find.text(stage.value), findsOneWidget);
      expect(
          find.textContaining(stage.key == 'firstFrame'
              ? l.resourceSnifferPreviewProtectedMedia
              : l.resourceSnifferPreviewCodecUnavailable),
          findsOneWidget);
      expect(find.textContaining('Private decoder error detail'), findsNothing);
    }
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('malformed diagnostic values and arbitrary fields are filtered and retry clears diagnostics',
      (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.text('media-1.mp4'));
    await tester.pumpAndSettle();
    final hostile = [
      {
        'stage': 'sourceOpen: https://secret.example.com?token=private',
        'httpStatus': '403 Authorization: secret',
        'nativeHRESULT': '0xC00D36C4 token=private',
        'mediaHeader': 'unrecognizedMp4 https://secret.example.com',
        'details': {'cookie': 'secret-cookie'},
      },
      {
        'stage': ['firstFrame'],
        'httpStatus': 600,
        'nativeHRESULT': '0xC00D36C4\n'
      },
      {'httpStatus': 99, 'nativeHRESULT': '0x123'},
      {'httpStatus': 403.0, 'nativeHRESULT': 1234},
    ];
    for (final diagnostics in hostile) {
      final pending = Completer<Map<String, dynamic>>();
      server.pending = pending;
      await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
      await tester.pump();
      pending.complete({'error': 'secret-cookie', 'code': 'unknown', 'diagnostics': diagnostics});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sniffer-preview-stage-1')), findsNothing);
      expect(find.byKey(const Key('sniffer-preview-http-status-1')), findsNothing);
      expect(find.byKey(const Key('sniffer-preview-native-code-1')), findsNothing);
      expect(find.byKey(const Key('sniffer-preview-media-header-1')), findsNothing);
      expect(find.textContaining('secret'), findsNothing);
      expect(find.textContaining('token=private'), findsNothing);
    }
    final valid = Completer<Map<String, dynamic>>();
    server.pending = valid;
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pump();
    valid.complete({
      'error': 'Decoder failure',
      'code': 'decodeFailed',
      'diagnostics': {'stage': 'firstFrame', 'mediaHeader': 'unrecognizedMp4'},
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-stage-1')), findsOneWidget);
    expect(find.byKey(const Key('sniffer-preview-media-header-1')), findsOneWidget);
    server.pending = null;
    server.preview = media();
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-stage-1')), findsNothing);
    expect(find.byKey(const Key('sniffer-preview-media-header-1')), findsNothing);
    expect(find.byKey(const Key('sniffer-preview-error-1')), findsNothing);
    expect(find.byKey(const Key('sniffer-preview-image-1')), findsOneWidget);
    final failedRefresh = Completer<Map<String, dynamic>>();
    server.pending = failedRefresh;
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pump();
    failedRefresh.complete({'error': 'Private decoder detail', 'code': 'codecUnavailable'});
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppLocalizationsEn().close));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: find.byKey(const Key('sniffer-preview-1')), matching: find.byType(Tooltip)).first);
    expect(tooltip.message,
        '${AppLocalizationsEn().resourceSnifferRetry}: ${AppLocalizationsEn().resourceSnifferPreviewCodecUnavailable}');
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('disposing cancels only the active request and ignores its late completion', (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    server.pending = pending;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    await _close(tester);
    expect(server.count('resourceSnifferCancelPreview'), 1);
    pending.complete({'preview': media()});
    await tester.pump(const Duration(seconds: 2));
    expect(server.count('resourceSnifferClear'), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two pages use distinct owners and a closing page cancels with its own client id', (tester) async {
    _size(tester, size: const Size(2200, 760));
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    server.pending = pending;
    final showFirst = ValueNotifier(true);
    addTearDown(showFirst.dispose);
    await tester.pumpWidget(_page(server,
        home: ValueListenableBuilder<bool>(
          valueListenable: showFirst,
          builder: (_, visible, child) => Row(children: [
            Expanded(
              child: visible
                  ? ResourceSnifferPage(key: const ValueKey('first-window'), command: server.call)
                  : const SizedBox(),
            ),
            Expanded(child: ResourceSnifferPage(key: const ValueKey('second-window'), command: server.call)),
          ]),
        )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')).first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')).last);
    await tester.pump();
    final requests = server.calls.where((call) => call.$1 == 'resourceSnifferPreview').toList();
    expect(requests.length, 2);
    expect(requests.first.$2['clientId'], isNot(requests.last.$2['clientId']));
    showFirst.value = false;
    await tester.pump();
    final cancellations = server.calls.where((call) => call.$1 == 'resourceSnifferCancelPreview').toList();
    expect(cancellations.length, 1);
    expect(cancellations.single.$2, requests.first.$2);
    pending.complete({'preview': media()});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsOneWidget);
    expect(find.text('1920 × 1080'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('native X waits for cancel IPC before releasing prevention and closing the child', (tester) async {
    _size(tester);
    final native = _nativeWindowCalls(tester);
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    final cancellation = Completer<Map<String, dynamic>>();
    server.pending = pending;
    server.pendingCancellation = cancellation;
    await tester
        .pumpWidget(_page(server, home: ResourceSnifferPage(windowId: 'sniffer-native-child', command: server.call)));
    await tester.pump();
    expect(native.single.method, 'setPreventClose');
    expect(native.single.arguments, {'isPreventClose': true});
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    await _nativeClose(tester);
    await tester.pump();
    expect(server.count('resourceSnifferCancelPreview'), 1);
    final cancelArguments = server.calls.firstWhere((call) => call.$1 == 'resourceSnifferCancelPreview').$2;
    expect(cancelArguments, server.calls.firstWhere((call) => call.$1 == 'resourceSnifferPreview').$2);
    expect(native.length, 1); // Engine remains alive until the main window acknowledges cancellation.
    final queryCount = server.count('resourceSnifferQuery');
    await _nativeClose(tester); // Repeated native close events must not send duplicate cancellations.
    await tester.pump(const Duration(seconds: 1));
    expect(server.count('resourceSnifferQuery'), queryCount);
    expect(server.count('resourceSnifferCancelPreview'), 1);
    expect(native.length, 1);
    cancellation.complete({'cancelled': true});
    await tester.pumpAndSettle();
    expect(native.map((call) => call.method), ['setPreventClose', 'setPreventClose', 'close']);
    expect(native[1].arguments, {'isPreventClose': false});
    pending.complete({'preview': media()});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-1')), findsNothing);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('native close remains usable when the main window never acknowledges cancellation', (tester) async {
    _size(tester);
    final native = _nativeWindowCalls(tester);
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    final cancellation = Completer<Map<String, dynamic>>();
    server.pending = pending;
    server.pendingCancellation = cancellation;
    await tester
        .pumpWidget(_page(server, home: ResourceSnifferPage(windowId: 'sniffer-native-child', command: server.call)));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    await _nativeClose(tester);
    await tester.pump();
    expect(native.where((call) => call.method == 'close'), isEmpty);
    await tester.pump(const Duration(milliseconds: 2001));
    await tester.pump();
    expect(native.map((call) => call.method), ['setPreventClose', 'setPreventClose', 'close']);
    cancellation.complete({'cancelled': true});
    pending.complete({'preview': media()});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('native close without an active preview is immediate and embedded pages do not intercept windows',
      (tester) async {
    _size(tester);
    final native = _nativeWindowCalls(tester);
    final server = _PreviewServer([_resource('1')]);
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await _nativeClose(tester);
    await tester.pump();
    expect(native, isEmpty);
    await tester.pumpWidget(_page(server,
        home:
            ResourceSnifferPage(key: const ValueKey('child'), windowId: 'sniffer-native-child', command: server.call)));
    await tester.pump();
    await _nativeClose(tester);
    await tester.pumpAndSettle();
    expect(native.map((call) => call.method), ['setPreventClose', 'setPreventClose', 'close']);
    expect(server.count('resourceSnifferCancelPreview'), 0);
    expect(server.count('resourceSnifferClear'), 0);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('collection generation cancels remote clear but an empty filter preserves the active preview',
      (tester) async {
    _size(tester);
    final server = _PreviewServer([_resource('1')]);
    final pending = Completer<Map<String, dynamic>>();
    server.pending = pending;
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-preview-1')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'no-match');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(server.count('resourceSnifferCancelPreview'), 0);
    server.resources = [];
    server.collectionGeneration++;
    server.revision++;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(server.count('resourceSnifferCancelPreview'), 1);
    pending.complete({'preview': media()});
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    await _close(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manifest preview shows variants without requesting media segments or a frame', (tester) async {
    _size(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final server = _PreviewServer([_resource('1', kind: 'hls')]);
    server.preview = {
      'type': 'manifest',
      'container': 'HLS',
      'variants': [
        {'width': 1280, 'height': 720, 'bandwidth': 1500000, 'codec': 'avc1.4d401f', 'uri': 'stream-720.m3u8'},
      ],
    };
    await tester.pumpWidget(_page(server));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sniffer-resource-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sniffer-preview-detail-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('stream-720.m3u8'), findsOneWidget);
    expect(find.textContaining('1280 × 720 · 1.50 Mbps · avc1.4d401f'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(server.count('resourceSnifferPreview'), 1);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('unsupported platform and non-GET entries disable requests; narrow details do not overflow',
      (tester) async {
    _size(tester, size: const Size(640, 560));
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final server = _PreviewServer([
      _resource('1'),
      _resource('2', kind: 'image', method: 'POST'),
      _resource('3', kind: 'image'),
    ]);
    await tester.pumpWidget(_page(server));
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(const Key('sniffer-preview-1'))).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const Key('sniffer-preview-2'))).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const Key('sniffer-preview-3'))).onPressed, isNotNull);
    await tester.tap(find.text('media-1.mp4'));
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('sniffer-preview-detail-1'))).onPressed, isNull);
    expect(server.count('resourceSnifferPreview'), 0);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('cached scalar metadata renders without an automatic frame request', (tester) async {
    _size(tester);
    final entry = _resource('1')..['preview'] = {'width': 640, 'height': 360, 'durationMs': 45000, 'container': 'MP4'};
    final server = _PreviewServer([entry]);
    await tester.pumpWidget(_page(server));
    await tester.pump();
    expect(find.text('640 × 360'), findsOneWidget);
    expect(find.text('00:45'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(server.count('resourceSnifferPreview'), 0);
    await _close(tester);
  });

  testWidgets('browsing more than 32 previews evicts the oldest local frame', (tester) async {
    _size(tester);
    final server = _PreviewServer(List.generate(33, (index) => _resource('$index')));
    server.preview = media();
    await tester.pumpWidget(_page(server));
    await tester.pump();
    for (var index = 0; index < 33; index++) {
      await tester.enterText(find.byKey(const Key('sniffer-search')), 'media-$index.mp4');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('sniffer-preview-$index')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('sniffer-preview-thumbnail-$index')), findsOneWidget);
    }
    expect(server.count('resourceSnifferPreview'), 33);
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'media-0.mp4');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-0')), findsNothing);
    expect(find.text('1920 × 1080'), findsNothing);
    await tester.enterText(find.byKey(const Key('sniffer-search')), 'media-32.mp4');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const Key('sniffer-preview-thumbnail-32')), findsOneWidget);
    expect(server.count('resourceSnifferPreview'), 33);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });
}
