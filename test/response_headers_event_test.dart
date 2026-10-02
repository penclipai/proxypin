import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/components/manager/resource_sniffer_manager.dart';
import 'package:proxypin/network/http/codec.dart';
import 'package:proxypin/network/http/h2/frame.dart';
import 'package:proxypin/network/http/h2/h2_codec.dart';
import 'package:proxypin/network/http/h2/hpack/hpack.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_headers.dart';
import 'package:proxypin/network/util/byte_buf.dart';

class _Capture extends EventListener {
  final headers = <HttpResponse>[];
  final order = <String>[];
  final bool throwOnHeaders;

  _Capture({this.throwOnHeaders = false});

  @override
  void onRequest(Channel channel, HttpRequest request) {}

  @override
  void onResponseHeaders(ChannelContext channelContext, HttpResponse response) {
    if (throwOnHeaders) throw StateError('observer failed');
    headers.add(response);
    order.add('headers');
    expect(response.body, isNull);
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) => order.add('response');
}

HttpRequest _request({HttpMethod method = HttpMethod.get}) => HttpRequest(method, 'https://example.test/video?id=1');

ChannelContext _context(_Capture listener, {bool h2 = false, HttpMethod method = HttpMethod.get}) {
  final context = ChannelContext()
    ..listener = listener
    ..isHttp2PriorKnowledge = h2;
  final request = _request(method: method);
  if (h2) {
    request.streamId = 1;
    context.putStreamRequest(1, request);
  } else {
    context.currentRequest = request;
  }
  return context;
}

List<int> _frame(FrameType type, int flags, List<int> payload, {int stream = 1}) => [
      ...FrameHeader(payload.length, type, flags, stream).encode(),
      ...payload,
    ];

List<int> _block({String status = '200', String mime = 'video/mp4', String? length}) => HPackEncoder().encode([
      Header.ascii(':status', status),
      Header.ascii('content-type', mime),
      if (length != null) Header.ascii('content-length', length),
    ]);

void main() {
  group('HTTP/1 response headers event', () {
    test('waits for complete headers at every socket split and fires before body', () {
      final wire = ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 5\r\n\r\n');
      for (var split = 1; split < wire.length; split++) {
        final capture = _Capture();
        final context = _context(capture);
        final request = context.currentRequest;
        final codec = HttpResponseCodec();
        final buffer = ByteBuf(wire.sublist(0, split));
        final first = codec.decode(context, buffer);
        expect(first.isDone, isFalse, reason: 'split=$split');
        expect(capture.headers, isEmpty, reason: 'split=$split');
        buffer.add(wire.sublist(split));
        final second = codec.decode(context, buffer);
        expect(second.isDone, isFalse, reason: 'split=$split');
        expect(capture.headers, hasLength(1), reason: 'split=$split');
        expect(capture.headers.single.headers.contentType, 'video/mp4');
        expect(context.currentRequest, same(request));
        expect(request?.response, isNull);
        buffer.add(ascii.encode('media'));
        final finalResult = codec.decode(context, buffer);
        expect(finalResult.isDone, isTrue);
        expect(finalResult.data?.bodyAsString, 'media');
        expect(capture.headers, hasLength(1));
      }
    });

    test('announces a large response without waiting for its declared body', () {
      final capture = _Capture();
      final result = HttpResponseCodec().decode(_context(capture),
          ByteBuf(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 9999999\r\n\r\n')));
      expect(result.isDone, isFalse);
      expect(capture.headers.single.contentLength, 9999999);
      expect(result.data?.body, isNull);
    });

    for (final (name, contentHeaders) in [
      ('FLV', 'Content-Type: video/x-flv\r\n'),
      ('unknown length', 'Content-Type: audio/mpeg\r\n'),
    ]) {
      test('announces $name while preserving raw forwarding', () {
        final capture = _Capture();
        final payload = ascii.encode('stream bytes');
        final result = HttpResponseCodec().decode(
            _context(capture), ByteBuf([...ascii.encode('HTTP/1.1 200 OK\r\n$contentHeaders\r\n'), ...payload]));
        expect(capture.headers, hasLength(1));
        expect(result.supportedParse, isFalse);
        expect(result.isDone, isFalse);
        expect(result.forward, payload);
        expect(result.data?.body, isNull);
      });
    }

    test('preserves partial content metadata and body decoding', () {
      final capture = _Capture();
      final result = HttpResponseCodec().decode(
          _context(capture),
          ByteBuf(ascii.encode('HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\n'
              'Content-Range: bytes 5-7/100\r\nContent-Length: 3\r\n\r\nabc')));
      expect(capture.headers.single.status.code, 206);
      expect(capture.headers.single.headers.get('Content-Range'), 'bytes 5-7/100');
      expect(result.isDone, isTrue);
      expect(result.data?.bodyAsString, 'abc');
    });

    test('skips interim response headers and announces the following final response', () {
      final capture = _Capture();
      final codec = HttpResponseCodec();
      final context = _context(capture);
      final interim = codec.decode(context, ByteBuf(ascii.encode('HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n')));
      expect(interim.isDone, isTrue);
      expect(capture.headers, isEmpty);
      codec.decode(
          context, ByteBuf(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 0\r\n\r\n')));
      expect(capture.headers.single.status.code, 200);
    });

    test('does not announce CONNECT tunnel negotiation from either source', () {
      final capture = _Capture();
      final context = _context(capture, method: HttpMethod.connect);
      final response = ascii.encode('HTTP/1.1 200 Connection established\r\n\r\n');
      expect(HttpResponseCodec().decode(context, ByteBuf(response)).isDone, isTrue);
      final codec = HttpClientCodec();
      final context2 = ChannelContext()..listener = capture;
      codec.encode(context2, _request(method: HttpMethod.connect));
      expect(codec.decode(context2, ByteBuf(response)).isDone, isTrue);
      expect(capture.headers, isEmpty);
    });

    test('isolates an observer failure from body decoding', () {
      final capture = _Capture(throwOnHeaders: true);
      final result = HttpResponseCodec()
          .decode(_context(capture), ByteBuf(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc')));
      expect(result.isDone, isTrue);
      expect(result.data?.bodyAsString, 'abc');
    });
  });

  group('HTTP/2 response headers event', () {
    test('associates the stream request and announces before DATA END_STREAM', () {
      final capture = _Capture();
      final context = _context(capture, h2: true);
      final request = context.getStreamRequest(1);
      final codec = HttpResponseCodec();
      final headerResult = codec.decode(context, ByteBuf(_frame(FrameType.headers, 4, _block(length: '3'))));
      expect(headerResult.isDone, isFalse);
      expect(capture.headers, hasLength(1));
      expect(capture.headers.single.request, same(request));
      expect(capture.headers.single.requestId, request?.requestId);
      expect(capture.headers.single.streamId, 1);
      final bodyResult = codec.decode(context, ByteBuf(_frame(FrameType.data, 1, ascii.encode('abc'))));
      expect(bodyResult.isDone, isTrue);
      expect(bodyResult.data?.bodyAsString, 'abc');
      expect(capture.headers, hasLength(1));
    });

    test('waits for END_HEADERS at every HPACK literal split', () {
      final block = _block(length: '3');
      for (var split = 1; split < block.length; split++) {
        final capture = _Capture();
        final context = _context(capture, h2: true);
        final codec = HttpResponseCodec();
        final first = codec.decode(context, ByteBuf(_frame(FrameType.headers, 0, block.sublist(0, split))));
        expect(first.isDone, isFalse);
        expect(capture.headers, isEmpty, reason: 'split=$split');
        expect(context.getStreamResponse(1), isNull);
        final second = codec.decode(context, ByteBuf(_frame(FrameType.continuation, 4, block.sublist(split))));
        expect(second.isDone, isFalse);
        expect(capture.headers, hasLength(1), reason: 'split=$split');
        expect(capture.headers.single.headers.contentType, 'video/mp4');
        expect(capture.headers.single.request, same(context.getStreamRequest(1)));
      }
    });

    test('retains fragmented header frames at every socket split', () {
      final block = _block();
      final wire = [
        ..._frame(FrameType.headers, 0, block.sublist(0, 7)),
        ..._frame(FrameType.continuation, 4, block.sublist(7)),
      ];
      for (var split = 1; split < wire.length; split++) {
        final capture = _Capture();
        final context = _context(capture, h2: true);
        final codec = HttpResponseCodec();
        final buffer = ByteBuf(wire.sublist(0, split));
        codec.decode(context, buffer);
        expect(capture.headers, isEmpty, reason: 'split=$split');
        buffer.clearRead();
        buffer.add(wire.sublist(split));
        expect(codec.decode(context, buffer).isDone, isFalse);
        expect(capture.headers, hasLength(1), reason: 'split=$split');
      }
    });

    test('supports multiple CONTINUATION frames and initial END_STREAM', () {
      final capture = _Capture();
      final context = _context(capture, h2: true);
      final codec = HttpResponseCodec();
      final block = _block(status: '304');
      codec.decode(context, ByteBuf(_frame(FrameType.headers, 1, block.sublist(0, 1))));
      codec.decode(context, ByteBuf(_frame(FrameType.continuation, 0, block.sublist(1, 6))));
      expect(capture.headers, isEmpty);
      final result = codec.decode(context, ByteBuf(_frame(FrameType.continuation, 4, block.sublist(6))));
      expect(result.isDone, isTrue);
      expect(result.data?.status.code, 304);
      expect(capture.headers, hasLength(1));
      expect(context.getStreamResponse(1), isNull);
    });

    test('does not duplicate callbacks for complete or fragmented trailers', () {
      for (final splitTrailers in [false, true]) {
        final capture = _Capture();
        final context = _context(capture, h2: true);
        final codec = HttpResponseCodec();
        codec.decode(context, ByteBuf(_frame(FrameType.headers, 4, _block())));
        codec.decode(context, ByteBuf(_frame(FrameType.data, 0, ascii.encode('abc'))));
        final trailers = HPackEncoder().encode([Header.ascii('x-checksum', '1234')]);
        final DecoderResult<HttpResponse> result;
        if (splitTrailers) {
          codec.decode(context, ByteBuf(_frame(FrameType.headers, 1, trailers.sublist(0, 3))));
          result = codec.decode(context, ByteBuf(_frame(FrameType.continuation, 4, trailers.sublist(3))));
        } else {
          result = codec.decode(context, ByteBuf(_frame(FrameType.headers, 5, trailers)));
        }
        expect(result.isDone, isTrue);
        expect(result.data?.bodyAsString, 'abc');
        expect(result.data?.headers.get('x-checksum'), '1234');
        expect(capture.headers, hasLength(1));
      }
    });

    test('ignores interim status and replaces it with final headers', () {
      final capture = _Capture();
      final context = _context(capture, h2: true);
      final codec = HttpResponseCodec();
      codec.decode(context, ByteBuf(_frame(FrameType.headers, 4, _block(status: '103', mime: 'text/plain'))));
      expect(capture.headers, isEmpty);
      codec.decode(context, ByteBuf(_frame(FrameType.headers, 4, _block())));
      expect(capture.headers.single.status.code, 200);
      expect(capture.headers.single.headers.contentType, 'video/mp4');
    });

    test('observes SSE headers before its existing response callback and relays all header frames', () {
      final capture = _Capture();
      final context = _context(capture, h2: true);
      final codec = HttpResponseCodec();
      final block = _block(mime: 'text/event-stream');
      final first = _frame(FrameType.headers, 0, block.sublist(0, 4));
      final second = _frame(FrameType.continuation, 4, block.sublist(4));
      codec.decode(context, ByteBuf(first));
      expect(capture.order, isEmpty);
      final result = codec.decode(context, ByteBuf(second));
      expect(result.isDone, isFalse);
      expect(result.forward, [...first, ...second]);
      expect(capture.order, ['headers', 'response']);
    });

    test('keeps fragmented request headers and streaming upload behavior', () {
      final context = ChannelContext();
      final decoder = Http2RequestDecoder();
      final block = HPackEncoder().encode([
        Header.ascii(':method', 'POST'),
        Header.ascii(':scheme', 'https'),
        Header.ascii(':authority', 'example.test'),
        Header.ascii(':path', '/upload'),
        Header.ascii('content-length', '9999999'),
      ]);
      expect(decoder.decode(context, ByteBuf(_frame(FrameType.headers, 0, block.sublist(0, 2)))).isDone, isFalse);
      final result = decoder.decode(context, ByteBuf(_frame(FrameType.continuation, 4, block.sublist(2))));
      expect(result.isDone, isTrue);
      expect(result.data?.streamingBody, isTrue);
      expect(result.data?.body, isNull);
      expect(result.data?.requestUrl, 'https://example.test/upload');
      expect(result.data?.contentLength, 9999999);
    });

    test('bounds pending headers and recovers after the stream error', () {
      final capture = _Capture();
      final context = _context(capture, h2: true);
      final codec = HttpResponseCodec();
      codec.decode(context, ByteBuf(_frame(FrameType.headers, 0, [0])));
      expect(
          () => codec.decode(
              context, ByteBuf(_frame(FrameType.continuation, 0, List.filled(Codec.defaultMaxInitialLineLength, 0)))),
          throwsA(isA<ParserException>()));
      codec.decode(context, ByteBuf(_frame(FrameType.headers, 4, _block())));
      expect(capture.headers, hasLength(1));
    });

    test('clears incomplete header state after reset', () {
      final capture = _Capture();
      final context = _context(capture, h2: true);
      final codec = HttpResponseCodec();
      codec.decode(context, ByteBuf(_frame(FrameType.headers, 0, _block().sublist(0, 3))));
      codec.decode(context, ByteBuf(_frame(FrameType.rstStream, 0, [0, 0, 0, 8])));
      final continuation = _frame(FrameType.continuation, 4, [1, 2, 3]);
      final result = codec.decode(context, ByteBuf(continuation));
      expect(result.forward, continuation);
      expect(capture.headers, isEmpty);
    });
  });

  test('combined listener continues notifying observers after one fails', () {
    final failing = _Capture(throwOnHeaders: true);
    final healthy = _Capture();
    final listener = CombinedEventListener([failing, healthy]);
    final context = ChannelContext()..listener = listener;
    final result = HttpResponseCodec().decode(
        context, ByteBuf(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 0\r\n\r\n')));
    expect(result.isDone, isTrue);
    expect(healthy.headers, hasLength(1));
    expect(healthy.headers.single.headers.get(HttpHeaders.CONTENT_TYPE), 'audio/mpeg');
  });

  group('decoder to resource sniffer integration', () {
    late Directory directory;
    late ResourceSnifferManager manager;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('sniffer_decoder_test_');
      manager = ResourceSnifferManager(configPath: '${directory.path}${Platform.pathSeparator}resource_sniffer.json');
      await manager.initialize();
    });

    tearDown(() async => directory.delete(recursive: true));

    Future<Map<String, dynamic>> query() => manager.handleCommand('resourceSnifferQuery', {});

    test('HTTP/1 metadata is queryable before its body arrives and final does not double count', () async {
      final request = _request();
      final context = ChannelContext()
        ..currentRequest = request
        ..listener = manager;
      final codec = HttpResponseCodec();
      final buffer = ByteBuf(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n'));
      expect(codec.decode(context, buffer).isDone, isFalse);
      expect((await query())['total'], 0);
      buffer.add(ascii.encode('Content-Length: 3\r\n\r\n'));
      expect(codec.decode(context, buffer).isDone, isFalse);
      var entry = ((await query())['resources'] as List).single as Map;
      expect(entry['url'], request.requestUrl);
      expect(entry['kind'], 'audio');
      expect(entry['hitCount'], 1);
      expect(entry['sizeBytes'], 3);
      expect(request.response, isNull);
      buffer.add(ascii.encode('abc'));
      final result = codec.decode(context, buffer);
      expect(result.isDone, isTrue);
      context.listener!.onResponse(context, result.data!);
      entry = ((await query())['resources'] as List).single as Map;
      expect(entry['hitCount'], 1);
      expect(result.data!.bodyAsString, 'abc');
    });

    test('HTTP/2 metadata appears after END_HEADERS before DATA and final retains request dedup', () async {
      final request = _request()..streamId = 1;
      final context = ChannelContext()
        ..isHttp2PriorKnowledge = true
        ..listener = manager;
      context.putStreamRequest(1, request);
      final codec = HttpResponseCodec();
      final block = _block(mime: 'application/vnd.apple.mpegurl', length: '3');
      expect(codec.decode(context, ByteBuf(_frame(FrameType.headers, 0, block.sublist(0, 5)))).isDone, isFalse);
      expect((await query())['total'], 0);
      expect(codec.decode(context, ByteBuf(_frame(FrameType.continuation, 4, block.sublist(5)))).isDone, isFalse);
      var entry = ((await query())['resources'] as List).single as Map;
      expect(entry['url'], request.requestUrl);
      expect(entry['kind'], 'hls');
      expect(entry['requestId'], request.requestId);
      expect(entry['hitCount'], 1);
      expect(context.getStreamResponse(1)?.body, isNull);
      final result = codec.decode(context, ByteBuf(_frame(FrameType.data, 1, ascii.encode('abc'))));
      expect(result.isDone, isTrue);
      expect(context.getStreamRequest(1), isNull);
      context.listener!.onResponse(context, result.data!);
      entry = ((await query())['resources'] as List).single as Map;
      expect(entry['requestId'], request.requestId);
      expect(entry['hitCount'], 1);
      expect(result.data!.bodyAsString, 'abc');
    });
  });
}
