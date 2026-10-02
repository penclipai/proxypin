import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_preview.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_sniffer.dart';

class _Request {
  final String url;
  final String method;
  final Map<String, String> headers;

  _Request(HttpRequest request)
      : url = request.uri.toString(),
        method = request.method,
        headers = {
          for (final name in ['range', 'referer', 'origin', 'user-agent', 'cookie', 'authorization', 'x-token'])
            if (request.headers.value(name) != null) name: request.headers.value(name)!
        };
}

class _ProxyHttpOverrides extends HttpOverrides {
  final int proxyPort;
  int clientsCreated = 0;
  int proxyLookups = 0;

  _ProxyHttpOverrides(this.proxyPort);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clientsCreated++;
    return super.createHttpClient(context)
      ..findProxy = (_) {
        proxyLookups++;
        return 'PROXY 127.0.0.1:$proxyPort';
      };
  }
}

class _Fixture {
  final HttpServer server;
  final List<_Request> requests = [];
  final Future<void> Function(HttpRequest)? handler;

  _Fixture._(this.server, this.handler) {
    server.listen((request) async {
      requests.add(_Request(request));
      try {
        if (handler != null) {
          await handler!(request);
          return;
        }
        final body = List<int>.generate(512, (index) => index % 256);
        request.response.headers.contentType = ContentType('video', 'mp4');
        final range = request.headers.value('range');
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
          final start = int.parse(match[1]!);
          final end = int.parse(match[2]!).clamp(start, body.length - 1);
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes $start-$end/${body.length}');
          request.response.contentLength = end - start + 1;
          request.response.add(body.sublist(start, end + 1));
        } else {
          request.response.contentLength = body.length;
          if (request.method != 'HEAD') request.response.add(body);
        }
        await request.response.close();
      } catch (_) {
        // Cancellation closes both sides of an intentionally held response.
      }
    });
  }

  static Future<_Fixture> create({Future<void> Function(HttpRequest)? handler}) async =>
      _Fixture._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), handler);

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> close() => server.close(force: true);
}

Future<Map<String, Object>> _readBridge(Uri url, {String? range, String method = 'GET'}) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.openUrl(method, url);
    if (range != null) request.headers.set('range', range);
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (old, chunk) => old..addAll(chunk));
    return {
      'status': response.statusCode,
      'range': response.headers.value('content-range') ?? '',
      'length': response.contentLength,
      'bytes': bytes,
    };
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? oldOverrides;
  final fixtures = <_Fixture>[];
  final services = <ResourcePreviewService>[];
  final png = Uint8List.fromList([137, 80, 78, 71]);

  Future<_Fixture> fixture({Future<void> Function(HttpRequest)? handler}) async {
    final value = await _Fixture.create(handler: handler);
    fixtures.add(value);
    return value;
  }

  ResourcePreviewService service({
    ResourceMediaDecoder? decoder,
    ResourceMediaCanceller? canceller,
    ResourceImageDecoder? imageDecoder,
    int maxBytes = 16 * 1024 * 1024,
    int maxImageBytes = 8 * 1024 * 1024,
    int maxCachedEntries = 32,
    int maxCachedImageBytes = 16 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final value = ResourcePreviewService(
      mediaDecoder: decoder ??
          (url) async {
            await _readBridge(url);
            return {'imageBytes': png, 'width': 640, 'height': 360, 'durationMs': 1234, 'codec': 'H264'};
          },
      imageDecoder: imageDecoder ?? (_) async => {'imageBytes': png, 'width': 10, 'height': 20},
      mediaCanceller: canceller,
      maxBytes: maxBytes,
      maxImageBytes: maxImageBytes,
      maxCachedEntries: maxCachedEntries,
      maxCachedImageBytes: maxCachedImageBytes,
      timeout: timeout,
    );
    services.add(value);
    return value;
  }

  Future<ResourcePreviewResult> preview(
    ResourcePreviewService value,
    Uri url, {
    String id = 'one',
    ResourceKind kind = ResourceKind.video,
    Map<String, String> headers = const {},
    String method = 'GET',
    String clientId = 'legacy',
  }) =>
      value.preview(id: id, url: url.toString(), kind: kind, headers: headers, method: method, clientId: clientId);

  TypeMatcher<ResourcePreviewException> error(String code) =>
      isA<ResourcePreviewException>().having((e) => e.code, 'code', code);

  setUp(() {
    oldOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDown(() async {
    for (final value in services) {
      value.clear();
    }
    services.clear();
    for (final value in fixtures) {
      await value.close();
    }
    fixtures.clear();
    HttpOverrides.global = oldOverrides;
  });

  test('only an explicit preview requests the exact signed URL and private headers', () async {
    final source = await fixture();
    final value = service();
    expect(source.requests, isEmpty);
    final result = await preview(value, source.uri('/movie.mp4?signature=one%2Ftwo&expires=999'), headers: {
      'referer': 'https://player.example/watch',
      'origin': 'https://player.example',
      'user-agent': 'Captured Browser',
      'cookie': 'token=private',
      'authorization': 'Bearer secret',
      'x-token': 'extra',
    });
    expect(source.requests.single.url, '/movie.mp4?signature=one%2Ftwo&expires=999');
    expect(source.requests.single.headers['cookie'], 'token=private');
    expect(source.requests.single.headers['authorization'], 'Bearer secret');
    expect(source.requests.single.headers['referer'], 'https://player.example/watch');
    expect(source.requests.single.headers['origin'], 'https://player.example');
    expect(source.requests.single.headers['user-agent'], 'Captured Browser');
    expect(result.metadata, containsPair('width', 640));
    expect(result.toJson(), isNot(contains('imageBase64')));
    expect(result.toJson(includeImage: true)['imageBase64'], base64Encode(png));
    final json = jsonEncode(result.toJson(includeImage: true));
    expect(json, isNot(contains('private')));
    expect(json, isNot(contains('secret')));
    expect(json, isNot(contains('signature')));
  });

  test('media, manifests and images bypass an inherited proxy and read only the local origin', () async {
    final proxy = await fixture(handler: (request) async {
      request.response.statusCode = 502;
      request.response.contentLength = 0;
      await request.response.close();
    });
    final hls = utf8.encode('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nchild.m3u8\n');
    final dash = utf8.encode('<MPD><Period><AdaptationSet><Representation width="640" height="360" '
        'bandwidth="800000"><SegmentTemplate media="segment.m4s"/>'
        '</Representation></AdaptationSet></Period></MPD>');
    var originBytes = 0;
    final source = await fixture(handler: (request) async {
      final path = request.uri.path;
      final List<int> body;
      if (path == '/master.m3u8') {
        body = hls;
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      } else if (path == '/manifest.mpd') {
        body = dash;
        request.response.headers.contentType = ContentType('application', 'dash+xml');
      } else if (path == '/image.png') {
        body = png;
        request.response.headers.contentType = ContentType('image', 'png');
      } else {
        body = List.generate(256, (index) => index);
        request.response.headers.contentType =
            path == '/audio.mp3' ? ContentType('audio', 'mpeg') : ContentType('video', 'mp4');
      }
      final range = request.headers.value('range');
      final List<int> bytes;
      if (range != null) {
        expect(range, 'bytes=0-31');
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 0-31/${body.length}');
        bytes = body.sublist(0, 32);
      } else {
        bytes = body;
      }
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      originBytes += bytes.length;
      await request.response.close();
    });
    final overrides = _ProxyHttpOverrides(proxy.server.port);
    HttpOverrides.global = overrides;

    // Prove the override routes an ordinary client to the proxy before checking
    // that every preview request replaces that inherited choice with DIRECT.
    final control = HttpClient();
    try {
      final response = await (await control.getUrl(source.uri('/control'))).close();
      expect(response.statusCode, 502);
      await response.drain<void>();
    } finally {
      control.close(force: true);
    }
    expect(proxy.requests, hasLength(1));
    expect(source.requests, isEmpty);
    expect(overrides.proxyLookups, 1);
    proxy.requests.clear();
    overrides.proxyLookups = 0;
    final clientsBeforePreview = overrides.clientsCreated;

    var decodedMedia = 0;
    var decodedImages = 0;
    final value = service(
      maxBytes: 1024,
      decoder: (url) async {
        expect(url.host, '127.0.0.1');
        final response = await _readBridge(url, range: 'bytes=0-31');
        expect(response['status'], 206);
        expect(response['bytes'], hasLength(32));
        decodedMedia++;
        return {'durationMs': 3000, 'codec': 'fixture'};
      },
      imageDecoder: (bytes) async {
        expect(bytes, png);
        decodedImages++;
        return {'imageBytes': png, 'width': 10, 'height': 20};
      },
    );
    for (final entry in {
      '/video.mp4?item=one%2Ftwo': ResourceKind.video,
      '/audio.mp3': ResourceKind.audio,
      '/master.m3u8': ResourceKind.hls,
      '/manifest.mpd': ResourceKind.dash,
      '/image.png': ResourceKind.image,
    }.entries) {
      final result = await preview(value, source.uri(entry.key), id: entry.key, kind: entry.value);
      expect(result.metadata, isNotEmpty);
    }
    expect(decodedMedia, 2);
    expect(decodedImages, 1);
    expect(overrides.clientsCreated - clientsBeforePreview, greaterThanOrEqualTo(7));
    expect(overrides.proxyLookups, 0);
    expect(proxy.requests, isEmpty);
    expect(source.requests.map((request) => request.url), [
      '/video.mp4?item=one%2Ftwo',
      '/audio.mp3',
      '/master.m3u8',
      '/manifest.mpd',
      '/image.png',
    ]);
    expect(originBytes, 64 + hls.length + dash.length + png.length);
    expect(source.requests.take(2).every((request) => request.headers['range'] == 'bytes=0-31'), true);
    expect(value.pendingCount, 0);
  });

  test('range bridge preserves partial status, complete size and bytes before decoding', () async {
    final source = await fixture();
    final value = service(decoder: (url) async {
      expect(url.host, '127.0.0.1');
      final response = await _readBridge(url, range: 'bytes=200-209');
      expect(response['status'], 206);
      expect(response['range'], 'bytes 200-209/512');
      expect(response['length'], 10);
      expect(response['bytes'], List.generate(10, (index) => index + 200));
      return {'imageBytes': png, 'width': 1920, 'height': 1080};
    });
    await preview(value, source.uri('/movie.mp4'));
    expect(source.requests.single.headers['range'], 'bytes=200-209');
  });

  test('HEAD metadata does not consume body bytes and a later range still reads', () async {
    final source = await fixture();
    final value = service(
        maxBytes: 10,
        decoder: (url) async {
          final head = await _readBridge(url, method: 'HEAD');
          expect(head['status'], 200);
          expect(head['length'], 512);
          expect(head['bytes'], isEmpty);
          final part = await _readBridge(url, range: 'bytes=200-209');
          expect(part['bytes'], hasLength(10));
          return {'durationMs': 3000, 'codec': 'AAC'};
        });
    final result = await preview(value, source.uri('/audio.m4a'), kind: ResourceKind.audio);
    expect(result.metadata['thumbnailAvailable'], false);
    expect(result.imageBytes, isNull);
    expect(source.requests.map((e) => e.method), ['HEAD', 'GET']);
  });

  test('cross origin redirects strip captured credentials and custom token headers', () async {
    final target = await fixture();
    final source = await fixture(handler: (request) async {
      request.response.statusCode = 302;
      request.response.headers.set('location', target.uri('/target.mp4?signature=new').toString());
      await request.response.close();
    });
    await preview(service(), source.uri('/redirect.mp4'), headers: {
      'authorization': 'Bearer secret',
      'cookie': 'private=1',
      'x-token': 'secret',
      'user-agent': 'Captured Browser',
    });
    expect(source.requests.single.headers['authorization'], 'Bearer secret');
    expect(target.requests.single.headers.keys, isNot(contains('authorization')));
    expect(target.requests.single.headers.keys, isNot(contains('cookie')));
    expect(target.requests.single.headers.keys, isNot(contains('x-token')));
    expect(target.requests.single.headers['user-agent'], 'Captured Browser');
    expect(target.requests.single.url, '/target.mp4?signature=new');
  });

  test('same origin redirects retain necessary credentials', () async {
    final source = await fixture(handler: (request) async {
      if (request.uri.path == '/redirect.png') {
        request.response.statusCode = 307;
        request.response.headers.set('location', '/target.png');
      } else {
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    await preview(service(), source.uri('/redirect.png'),
        kind: ResourceKind.image, headers: {'cookie': 'private=1', 'authorization': 'Bearer secret'});
    expect(source.requests.last.headers['cookie'], 'private=1');
    expect(source.requests.last.headers['authorization'], 'Bearer secret');
  });

  test('large servers ignoring Range fail without downloading a complete media body', () async {
    final source = await fixture(handler: (request) async {
      request.response.contentLength = 1024 * 1024;
      await request.response.flush();
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    await expectLater(preview(service(maxBytes: 64), source.uri('/large.mp4')), throwsA(error('byteLimit')));
    expect(source.requests.single.headers['range'], 'bytes=0-63');
  });

  test('the byte budget applies across multiple decoder range requests', () async {
    final source = await fixture();
    final value = service(
        maxBytes: 128,
        decoder: (url) async {
          await _readBridge(url, range: 'bytes=0-63');
          await _readBridge(url, range: 'bytes=64-127');
          await _readBridge(url, range: 'bytes=128-191');
          return {};
        });
    await expectLater(preview(value, source.uri('/movie.mp4')), throwsA(error('byteLimit')));
    expect(source.requests, hasLength(2));
    expect(value.cachedCount, 0);
  });

  test('oversized images are refused before decoding, including unknown length streams', () async {
    var decoded = false;
    final source = await fixture(handler: (request) async {
      request.response.add(List.filled(100, 1));
      await request.response.close();
    });
    final value = service(
        maxImageBytes: 20,
        imageDecoder: (_) async {
          decoded = true;
          return {};
        });
    await expectLater(preview(value, source.uri('/image.png'), kind: ResourceKind.image), throwsA(error('byteLimit')));
    expect(decoded, false);
  });

  test('cancel closes an active bridge and never caches its later decoder result', () async {
    final source = await fixture();
    final started = Completer<Uri>();
    final releaseDecoder = Completer<Map<String, dynamic>>();
    final value = service(decoder: (url) {
      started.complete(url);
      return releaseDecoder.future;
    });
    final pending = preview(value, source.uri('/movie.mp4'));
    final local = await started.future;
    final assertion = expectLater(pending, throwsA(error('cancelled')));
    value.cancel('one');
    await assertion;
    expect(value.pendingCount, 0);
    await expectLater(_readBridge(local), throwsA(isA<SocketException>()));
    releaseDecoder.complete({'imageBytes': png, 'width': 1, 'height': 1});
    await Future<void>.delayed(Duration.zero);
    expect(value.cachedCount, 0);
  });

  for (final action in ['cancel', 'remove', 'clear', 'timeout']) {
    test('$action during bridge binding closes the late loopback listener', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      final releaseBind = Completer<ServerSocket>();
      final enteredBind = Completer<void>();
      var decoderCalls = 0;
      final value = service(
          timeout: const Duration(milliseconds: 100),
          decoder: (_) async {
            decoderCalls++;
            return {};
          });
      try {
        await IOOverrides.runZoned(() async {
          final pending = preview(value, Uri.parse('http://127.0.0.1:54321/movie.mp4'));
          final assertion = expectLater(pending, throwsA(error(action == 'timeout' ? 'timeout' : 'cancelled')));
          await enteredBind.future;
          switch (action) {
            case 'cancel':
              value.cancel('one');
            case 'remove':
              value.remove('one');
            case 'clear':
              value.clear();
          }
          await assertion;
          expect(value.pendingCount, 0);

          // The bind finishes only after run() has already cleaned up and
          // returned. Its continuation still owns the real listening socket.
          releaseBind.complete(socket);
          final deadline = Stopwatch()..start();
          var closed = false;
          while (!closed && deadline.elapsed < const Duration(seconds: 1)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            try {
              final connection =
                  await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 100));
              connection.destroy();
            } on SocketException {
              closed = true;
            }
          }
          expect(closed, true, reason: 'A bridge completing after $action must not remain reachable');
          expect(decoderCalls, 0);
          expect(value.cachedCount, 0);
        }, serverSocketBind: (address, port, {int backlog = 0, bool v6Only = false, bool shared = false}) {
          enteredBind.complete();
          return releaseBind.future;
        });
      } finally {
        if (!releaseBind.isCompleted) releaseBind.complete(socket);
        await socket.close();
      }
    });
  }

  test('total deadline stops a decoder even if the platform future does not finish', () async {
    final source = await fixture();
    final started = Completer<Uri>();
    final value = service(
        timeout: const Duration(milliseconds: 100),
        decoder: (url) {
          started.complete(url);
          return Completer<Map<String, dynamic>>().future;
        });
    final result = preview(value, source.uri('/movie.mp4'));
    final local = await started.future;
    await expectLater(result, throwsA(error('timeout')));
    expect(value.pendingCount, 0);
    await expectLater(_readBridge(local), throwsA(isA<SocketException>()));
  });

  test('one closing window does not cancel a preview still owned by another window', () async {
    final source = await fixture();
    final started = Completer<void>();
    final decoder = Completer<Map<String, dynamic>>();
    var calls = 0;
    final value = service(decoder: (_) {
      calls++;
      started.complete();
      return decoder.future;
    });
    final a = preview(value, source.uri('/movie.mp4'), clientId: 'window-a');
    await started.future;
    final b = preview(value, source.uri('/movie.mp4'), clientId: 'window-b');
    value.cancel('one', clientId: 'window-a');
    expect(value.pendingCount, 1);
    decoder.complete({'imageBytes': png, 'width': 640, 'height': 360});
    expect((await b).metadata['width'], 640);
    await a;
    expect(calls, 1);
    expect(value.cachedCount, 1);
    value.cancel('one', clientId: 'window-b');
    expect(value.cachedCount, 1);
  });

  test('the last owner closing cancels shared work; cancelling an unknown owner changes nothing', () async {
    final source = await fixture();
    final started = Completer<void>();
    final decoder = Completer<Map<String, dynamic>>();
    final value = service(decoder: (_) {
      started.complete();
      return decoder.future;
    });
    final a = preview(value, source.uri('/movie.mp4'), clientId: 'window-a');
    await started.future;
    final b = preview(value, source.uri('/movie.mp4'), clientId: 'window-b');
    final assertionA = expectLater(a, throwsA(error('cancelled')));
    final assertionB = expectLater(b, throwsA(error('cancelled')));
    value.cancel('one', clientId: 'unknown');
    value.cancel('one', clientId: 'window-a');
    expect(value.pendingCount, 1);
    value.cancel('one', clientId: 'window-b');
    await Future.wait([assertionA, assertionB]);
    expect(value.pendingCount, 0);
    expect(value.cachedCount, 0);
    decoder.complete({});
  });

  test('the last owner cancels its platform session exactly once using only the local bridge URL', () async {
    final source = await fixture();
    final started = Completer<Uri>();
    final decoder = Completer<Map<String, dynamic>>();
    final cancelled = <Uri>[];
    final value = service(
        canceller: cancelled.add,
        decoder: (url) {
          started.complete(url);
          return decoder.future;
        });
    value.cancel('missing');
    expect(cancelled, isEmpty);
    final first = preview(value, source.uri('/movie.mp4?signature=private'), clientId: 'first');
    final local = await started.future;
    final second = preview(value, source.uri('/movie.mp4?signature=private'), clientId: 'second');
    final assertions = [
      expectLater(first, throwsA(error('cancelled'))),
      expectLater(second, throwsA(error('cancelled')))
    ];
    value.cancel('one', clientId: 'first');
    expect(cancelled, isEmpty);
    value.cancel('one', clientId: 'second');
    value.cancel('one', clientId: 'second');
    value.clear();
    await Future.wait(assertions);
    expect(cancelled, [local]);
    expect(cancelled.single.scheme, 'http');
    expect(cancelled.single.host, '127.0.0.1');
    expect(cancelled.single.hasPort, true);
    expect(cancelled.single.userInfo, isEmpty);
    expect(cancelled.single.query, isEmpty);
    expect(cancelled.single.toString(), isNot(contains('signature')));
    decoder.complete({});
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, hasLength(1));
  });

  test('invalid upstream ranges fail instead of feeding wrong offsets into the decoder', () async {
    final source = await fixture(handler: (request) async {
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-9/512');
      request.response.contentLength = 10;
      request.response.add(List.filled(10, 1));
      await request.response.close();
    });
    final value = service(decoder: (url) async {
      await _readBridge(url, range: 'bytes=200-209');
      return {};
    });
    await expectLater(preview(value, source.uri('/wrong.mp4')), throwsA(error('range')));
  });

  test('preview cache uses both an entry and PNG byte bound; cache hits make no request', () async {
    final source = await fixture();
    final value = service(maxCachedEntries: 2, maxCachedImageBytes: 8);
    await preview(value, source.uri('/one.mp4'), id: 'one');
    await preview(value, source.uri('/two.mp4'), id: 'two');
    await preview(value, source.uri('/one.mp4'), id: 'one');
    expect(source.requests, hasLength(2));
    await preview(value, source.uri('/three.mp4'), id: 'three');
    expect(value.cachedCount, 2);
    expect(value.cachedImageBytes, 8);
    await preview(value, source.uri('/two.mp4'), id: 'two');
    expect(source.requests, hasLength(4));
    value.remove('two');
    expect(value.cachedCount, 1);
    value.clear();
    expect(value.cachedCount, 0);
    expect(value.cachedImageBytes, 0);
  });

  test('HLS preview reads only its master manifest and reports declared variant information', () async {
    final source = await fixture(handler: (request) async {
      request.response.write('#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42e01e,mp4a.40.2",FRAME-RATE=25\n'
          'small.m3u8?signature=abc\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"\n'
          'large.m3u8\n');
      await request.response.close();
    });
    final result = await preview(service(), source.uri('/master.m3u8'), kind: ResourceKind.hls);
    expect(source.requests, hasLength(1));
    expect(result.imageBytes, isNull);
    expect(result.metadata['type'], 'manifest');
    expect(result.metadata['width'], 1920);
    expect(result.metadata['height'], 1080);
    expect(result.metadata['bitrate'], 4000000);
    expect(result.metadata.containsKey('live'), false);
    final variants = (result.metadata['variants'] as List).cast<Map<String, dynamic>>();
    expect(variants, hasLength(2));
    expect(variants.first['frameRate'], 25);
    expect(variants.first['url'], source.uri('/small.m3u8?signature=abc').toString());
  });

  test('HLS media duration and encryption are metadata only, without segment or key requests', () async {
    final source = await fixture(handler: (request) async {
      request.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:3.5,\none.ts\n#EXTINF:2.25,\ntwo.ts\n#EXT-X-ENDLIST\n');
      await request.response.close();
    });
    final result = await preview(service(), source.uri('/vod.m3u8'), kind: ResourceKind.hls);
    expect(result.metadata['durationMs'], 5750);
    expect(result.metadata['live'], false);
    expect(result.metadata['encrypted'], true);
    expect(source.requests, hasLength(1));
  });

  test('DASH parses namespace, inherited codecs, frame rate, duration and DRM declarations', () async {
    final source = await fixture(handler: (request) async {
      request.response.write(
          '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1M2.5S">'
          '<Period><AdaptationSet mimeType="video/mp4" codecs="avc1.640028" frameRate="30000/1001">'
          '<ContentProtection schemeIdUri="urn:uuid:test"/><Representation id="hd" width="1280" height="720" bandwidth="2000000">'
          '<SegmentTemplate media="segment-\$Number\$.m4s" initialization="init.mp4"/></Representation>'
          '</AdaptationSet></Period></MPD>');
      await request.response.close();
    });
    final result = await preview(service(), source.uri('/manifest.mpd'), kind: ResourceKind.dash);
    expect(result.metadata['width'], 1280);
    expect(result.metadata['durationMs'], 62500);
    expect(result.metadata['codec'], 'avc1.640028');
    expect(result.metadata['encrypted'], true);
    expect(((result.metadata['variants'] as List).first as Map)['frameRate'], closeTo(29.97, .01));
    expect(source.requests, hasLength(1));
  });

  test('non-GET and unsupported resources are rejected without a network request', () async {
    final source = await fixture();
    final value = service();
    await expectLater(preview(value, source.uri('/movie.mp4'), method: 'POST'), throwsA(error('unsupportedMethod')));
    await expectLater(preview(value, source.uri('/anything'), kind: ResourceKind.other), throwsA(error('unsupported')));
    expect(source.requests, isEmpty);
  });

  test('nonfinite manifest frame rates are omitted so IPC and JSON export remain valid', () async {
    final source = await fixture(handler: (request) async {
      if (request.uri.path.endsWith('m3u8')) {
        request.response.write('#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=640x360,FRAME-RATE=NaN\nvideo.m3u8\n');
      } else {
        request.response
            .write('<MPD><Period><AdaptationSet><Representation width="640" height="360" frameRate="Infinity/1"/>'
                '</AdaptationSet></Period></MPD>');
      }
      await request.response.close();
    });
    final value = service();
    for (final kind in [ResourceKind.hls, ResourceKind.dash]) {
      final result = await preview(value, source.uri(kind == ResourceKind.hls ? '/test.m3u8' : '/test.mpd'),
          id: kind.name, kind: kind);
      expect(() => jsonEncode(result.toJson()), returnsNormally);
      expect(result.metadata.containsKey('frameRate'), false);
      expect(((result.metadata['variants'] as List).single as Map).containsKey('frameRate'), false);
    }
  });

  test('diagnostics retain only safe enums, HTTP status and a normalized native HRESULT', () {
    const value = ResourcePreviewException('decodeFailed', 'Safe message', diagnostics: {
      'stage': 'sourceOpen',
      'httpStatus': 206,
      'nativeHRESULT': '0xc00d36c4',
      'mediaHeader': 'unrecognizedMp4',
      'url': 'https://example/?token=secret',
      'headers': {'Authorization': 'Bearer secret'},
      'message': 'private',
    });
    expect(value.diagnostics, {
      'stage': 'sourceOpen',
      'httpStatus': 206,
      'nativeHRESULT': '0xC00D36C4',
      'mediaHeader': 'unrecognizedMp4',
    });
    const invalid = ResourcePreviewException('decodeFailed', 'Safe message', diagnostics: {
      'stage': 'secret',
      'httpStatus': 999,
      'nativeHRESULT': '0xC00D36C4 https://example/?secret',
      'mediaHeader': 'bytes',
    });
    expect(invalid.diagnostics, isEmpty);
  });

  test('unsuccessful HTTP status remains visible without leaking URL or authentication headers', () async {
    final source = await fixture(handler: (request) async {
      request.response.statusCode = 403;
      request.response.write('private diagnostic response');
      await request.response.close();
    });
    await expectLater(
      preview(service(), source.uri('/image.png?signature=secret'),
          kind: ResourceKind.image, headers: {'authorization': 'Bearer secret'}),
      throwsA(error('httpStatus')
          .having((e) => e.diagnostics, 'diagnostics', {'stage': 'resourceRequest', 'httpStatus': 403})),
    );
  });

  test('GET-signed resources rejecting HEAD fall back to a one-byte GET for full HEAD metadata', () async {
    final source = await fixture(handler: (request) async {
      request.response.headers.contentType = ContentType('video', 'mp4');
      if (request.method == 'HEAD') {
        request.response.statusCode = 403;
      } else {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(request.headers.value('range')!)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes $start-$end/512');
        request.response.contentLength = end - start + 1;
        request.response.add(List.generate(end - start + 1, (index) => (start + index) % 256));
      }
      await request.response.close();
    });
    final value = service(
        maxBytes: 10,
        decoder: (url) async {
          final head = await _readBridge(url, method: 'HEAD');
          expect(head['status'], 200);
          expect(head['length'], 512);
          expect(head['range'], '');
          expect(head['bytes'], isEmpty);
          expect((await _readBridge(url, range: 'bytes=200-209'))['bytes'], hasLength(10));
          return {'width': 640, 'height': 360};
        });
    await preview(value, source.uri('/movie.mp4?signature=GET-only'), headers: {'cookie': 'required=1'});
    expect(source.requests.map((r) => r.method), ['HEAD', 'GET', 'GET']);
    expect(source.requests[1].headers['range'], 'bytes=0-0');
    expect(source.requests[1].headers['cookie'], 'required=1');
  });

  test('malformed DASH XML and invalid UTF8 manifests report parsing errors instead of codec failure', () async {
    final source = await fixture(handler: (request) async {
      if (request.uri.path.endsWith('.mpd')) {
        request.response.write('<MPD><Period></MPD>');
      } else {
        request.response.add([0xff, 0xfe, 0x80]);
      }
      await request.response.close();
    });
    for (final kind in [ResourceKind.dash, ResourceKind.hls]) {
      await expectLater(
        preview(service(), source.uri(kind == ResourceKind.dash ? '/bad.mpd' : '/bad.m3u8'), kind: kind),
        throwsA(error('manifest').having((e) => e.diagnostics['stage'], 'stage', 'manifestParse')),
      );
    }
  });

  test('a failed decoder plus an unrecognized actual MP4 header reports the evidence without retaining bytes',
      () async {
    final source = await fixture();
    final value = service(decoder: (url) async {
      await _readBridge(url, range: 'bytes=0-31');
      throw const ResourcePreviewException('decodeFailed', 'Native failure', diagnostics: {
        'stage': 'sourceOpen',
        'nativeHRESULT': '0xC00D36C4',
        'url': 'secret',
      });
    });
    await expectLater(
        preview(value, source.uri('/opaque.mp4?encfilekey=secret')),
        throwsA(error('invalidMediaHeader').having((e) => e.diagnostics, 'diagnostics', {
          'stage': 'sourceOpen',
          'httpStatus': 206,
          'nativeHRESULT': '0xC00D36C4',
          'mediaHeader': 'unrecognizedMp4',
        })));
    expect(value.cachedCount, 0);
  });

  test('unknown MP4-labelled bytes are not rejected if the actual decoder can read them', () async {
    final source = await fixture();
    final result = await preview(service(), source.uri('/opaque.mp4'));
    expect(result.metadata['width'], 640);
    expect(result.imageBytes, isNotNull);
  });

  test('a first frame arriving before the rest of a range remains successful during socket cleanup', () async {
    final releaseSource = Completer<void>();
    final source = await fixture(handler: (request) async {
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-524287/524288');
      request.response.contentLength = 524288;
      request.response.add(List.filled(65536, 1));
      await request.response.flush();
      await releaseSource.future;
      request.response.add(List.filled(458752, 2));
      await request.response.close();
    });
    final decoderClient = HttpClient()..findProxy = (_) => 'DIRECT';
    final value = service(decoder: (url) async {
      final response = await (await decoderClient.getUrl(url)).close();
      final first = Completer<void>();
      response.listen((chunk) {
        if (!first.isCompleted) first.complete();
      }, onError: (_) {});
      await first.future;
      return {'imageBytes': png, 'width': 640, 'height': 360};
    });
    try {
      final result = await preview(value, source.uri('/movie.mp4'));
      expect(result.metadata['width'], 640);
      expect(result.imageBytes, png);
      expect(value.cachedCount, 1);
      expect(value.pendingCount, 0);
    } finally {
      releaseSource.complete();
      decoderClient.close(force: true);
    }
  });

  test('legal MP4 box headers including extended-size and EOF-sized boxes are not marked opaque', () async {
    final source = await fixture(handler: (request) async {
      final bytes = Uint8List(32);
      final data = ByteData.sublistView(bytes);
      final variant = request.uri.queryParameters['box'];
      data.setUint32(
          0,
          variant == 'extended'
              ? 1
              : variant == 'eof'
                  ? 0
                  : 24);
      bytes.setRange(4, 8, latin1.encode(variant == 'eof' ? 'mdat' : 'ftyp'));
      if (variant == 'extended') data.setUint64(8, 32);
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-31/32');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    for (final box in ['normal', 'extended', 'eof']) {
      final value = service(decoder: (url) async {
        await _readBridge(url, range: 'bytes=0-31');
        throw const ResourcePreviewException('decodeFailed', 'Native failure',
            diagnostics: {'stage': 'firstFrame', 'nativeHRESULT': '0xC00D36BE'});
      });
      await expectLater(preview(value, source.uri('/valid.mp4?box=$box')),
          throwsA(error('decodeFailed').having((e) => e.diagnostics.containsKey('mediaHeader'), 'mediaHeader', false)));
    }
  });

  test('wrong MP4 MIME on another recognized format does not imply an opaque MP4 header', () async {
    final source = await fixture(handler: (request) async {
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-31/32');
      request.response.contentLength = 32;
      request.response.add([0x1a, 0x45, 0xdf, 0xa3, ...List.filled(28, 0)]);
      await request.response.close();
    });
    final value = service(decoder: (url) async {
      await _readBridge(url, range: 'bytes=0-31');
      throw const ResourcePreviewException('decodeFailed', 'Native failure');
    });
    await expectLater(preview(value, source.uri('/wrong.mp4')), throwsA(error('decodeFailed')));
  });

  test('explicit codec and protection errors take priority over an unknown file header', () async {
    final source = await fixture();
    for (final code in ['codecUnavailable', 'protectedMedia']) {
      final value = service(decoder: (url) async {
        await _readBridge(url, range: 'bytes=0-31');
        throw ResourcePreviewException(code, 'Native failure', diagnostics: {'stage': 'streamType'});
      });
      await expectLater(preview(value, source.uri('/opaque.mp4')), throwsA(error(code)));
    }
  });

  test('an upstream truncated response is a source read failure rather than a decoder or header failure', () async {
    final source = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((socket) {
      var replied = false;
      socket.listen((_) async {
        if (replied) return;
        replied = true;
        socket.add(latin1.encode('HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\n'
            'Content-Range: bytes 0-31/32\r\nContent-Length: 32\r\nConnection: close\r\n\r\n'));
        socket.add([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109]);
        await socket.flush();
        socket.destroy();
      });
    });
    try {
      final value = service(decoder: (url) async {
        await _readBridge(url, range: 'bytes=0-31');
        throw const ResourcePreviewException('decodeFailed', 'Native failure');
      });
      await expectLater(
          preview(value, Uri.parse('http://127.0.0.1:${source.port}/truncated.mp4')),
          throwsA(error('network')
              .having((e) => e.diagnostics, 'diagnostics', {'stage': 'resourceRead', 'httpStatus': 206})));
    } finally {
      await source.close();
    }
  });
}
