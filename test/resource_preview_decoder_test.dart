import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/native/resource_preview_decoder.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_preview.dart';

class _Session implements ResourceMediaSession {
  final Future<Map<String, dynamic>> Function(Uri) load;
  final Future<void>? closing;
  int disposeCount = 0;
  _Session(this.load, {this.closing});
  @override
  Future<Map<String, dynamic>> capture(Uri bridge) => load(bridge);
  @override
  Future<void> dispose() async {
    disposeCount++;
    await closing;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bridge = Uri.parse('http://127.0.0.1:54321/session-token/media.mp4');

  test('decoder only receives the loopback bridge and disposes after success', () async {
    final calls = <Uri>[];
    final session = _Session((url) async {
      calls.add(url);
      return {'width': 1280, 'height': 720, 'durationMs': 1500, 'codec': 'h264'};
    });
    final result = await ResourcePreviewDecoder.decode(bridge, createSession: () => session);
    expect(result['width'], 1280);
    expect(result['codec'], 'h264');
    expect(calls, [bridge]);
    expect(session.disposeCount, 1);
    for (final url in [
      'https://media.example/video.mp4',
      'http://localhost:54321/media.mp4',
      'file:///video.mp4',
      'http://secret@127.0.0.1:54321/media.mp4',
      'http://127.0.0.1/media.mp4'
    ]) {
      await expectLater(
          ResourcePreviewDecoder.decode(Uri.parse(url), createSession: () => session), throwsFormatException);
    }
    expect(calls, hasLength(1));
  });

  test('cancellation promptly disposes native session once and permits a later preview', () async {
    final started = Completer<void>();
    final pending = Completer<Map<String, dynamic>>();
    final session = _Session((_) {
      started.complete();
      return pending.future;
    });
    final result = ResourcePreviewDecoder.decode(bridge, createSession: () => session);
    final check = expectLater(
        result, throwsA(isA<ResourcePreviewException>().having((error) => error.code, 'reason', 'cancelled')));
    await started.future;
    ResourcePreviewDecoder.cancel(bridge);
    ResourcePreviewDecoder.cancel(bridge);
    await check;
    expect(session.disposeCount, 1);
    pending.complete({'width': 1});
    final next = _Session((_) async => {'width': 640});
    expect((await ResourcePreviewDecoder.decode(bridge, createSession: () => next))['width'], 640);
    expect(next.disposeCount, 1);
  });

  test('stalled decoding times out and still disposes the native session', () async {
    final pending = Completer<Map<String, dynamic>>();
    final session = _Session((_) => pending.future);
    await expectLater(
        ResourcePreviewDecoder.decode(bridge, createSession: () => session, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<ResourcePreviewException>()
            .having((error) => error.code, 'reason', 'timeout')
            .having((error) => error.diagnostics, 'stage', {'stage': 'firstFrame'})));
    expect(session.disposeCount, 1);
    pending.complete({'width': 1});
  });

  test('raw native failures never expose URLs, tokens or decoder log text', () async {
    final session = _Session((_) async => throw StateError('https://secret.example/?token=private'));
    await expectLater(
        ResourcePreviewDecoder.decode(bridge, createSession: () => session),
        throwsA(isA<ResourcePreviewException>()
            .having((error) => error.code, 'reason', 'decodeFailed')
            .having((error) => error.message, 'safe message', isNot(contains('private')))
            .having((error) => error.diagnostics, 'safe stage', {'stage': 'mediaDecode'})));
    expect(session.disposeCount, 1);
  });

  test('structured decoder failures retain their safe diagnostic stage', () async {
    final session = _Session((_) async => throw const ResourcePreviewException(
        'decodeFailed', 'The media could not be decoded',
        diagnostics: {'stage': 'sourceOpen'}));
    await expectLater(
        ResourcePreviewDecoder.decode(bridge, createSession: () => session),
        throwsA(isA<ResourcePreviewException>()
            .having((error) => error.diagnostics, 'safe stage', {'stage': 'sourceOpen'})));
    expect(session.disposeCount, 1);
  });

  test('a duplicate bridge is rejected while its decoder is running', () async {
    final pending = Completer<Map<String, dynamic>>();
    final session = _Session((_) => pending.future);
    final result = ResourcePreviewDecoder.decode(bridge, createSession: () => session);
    await expectLater(ResourcePreviewDecoder.decode(bridge, createSession: () => session),
        throwsA(isA<ResourcePreviewException>().having((error) => error.code, 'reason', 'busy')));
    pending.complete({'width': 1});
    await result;
    expect(session.disposeCount, 1);
  });

  test('slow native cleanup keeps its slot occupied after the bounded IPC wait', () async {
    final closing = Completer<void>();
    final session = _Session((_) async => {'width': 640}, closing: closing.future);
    expect((await ResourcePreviewDecoder.decode(bridge, createSession: () => session))['width'], 640);
    await expectLater(ResourcePreviewDecoder.decode(bridge, createSession: () => session),
        throwsA(isA<ResourcePreviewException>().having((error) => error.code, 'reason', 'busy')));
    expect(session.disposeCount, 1);
    closing.complete();
    await Future<void>.delayed(Duration.zero);
    final next = _Session((_) async => {'width': 1280});
    expect((await ResourcePreviewDecoder.decode(bridge, createSession: () => next))['width'], 1280);
  });

  test('image preview preserves resolution and produces a bounded PNG thumbnail', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 1536, 768), ui.Paint()..color = const ui.Color(0xff24a9c7));
    final picture = recorder.endRecording();
    final source = await picture.toImage(1536, 768);
    final encoded = await source.toByteData(format: ui.ImageByteFormat.png);
    source.dispose();
    picture.dispose();
    final result = await ResourcePreviewDecoder.decodeImage(encoded!.buffer.asUint8List());
    expect(result['width'], 1536);
    expect(result['height'], 768);
    final codec = await ui.instantiateImageCodec(result['imageBytes'] as Uint8List);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 768);
    expect(frame.image.height, 384);
    frame.image.dispose();
    codec.dispose();
  });

  test('empty, oversized and invalid image inputs fail without producing a preview', () async {
    await expectLater(ResourcePreviewDecoder.decodeImage(Uint8List(0)), throwsFormatException);
    await expectLater(ResourcePreviewDecoder.decodeImage(Uint8List(8 * 1024 * 1024 + 1)), throwsFormatException);
    await expectLater(ResourcePreviewDecoder.decodeImage(Uint8List.fromList([1, 2, 3])), throwsA(isA<Exception>()));
  });
}
