import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:device_info_plus/device_info_plus.dart';
// The platform interface is used only to isolate native device-info in this fixture.
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/components/manager/resource_sniffer_manager.dart';
import 'package:proxypin/network/http/h2/hpack/hpack.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/storage/path.dart';

const _preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';

List<int> _frame(int type, int flags, int stream, List<int> payload) => [
      payload.length >> 16,
      (payload.length >> 8) & 255,
      payload.length & 255,
      type,
      flags,
      (stream >> 24) & 127,
      (stream >> 16) & 255,
      (stream >> 8) & 255,
      stream & 255,
      ...payload,
    ];

class _FrameBuffer {
  final bytes = <int>[];

  List<(int, int, int, List<int>)> add(List<int> incoming) {
    bytes.addAll(incoming);
    final frames = <(int, int, int, List<int>)>[];
    while (bytes.length >= 9) {
      final length = bytes[0] << 16 | bytes[1] << 8 | bytes[2];
      if (bytes.length < length + 9) break;
      final stream = (bytes[5] & 127) << 24 | bytes[6] << 16 | bytes[7] << 8 | bytes[8];
      frames.add((bytes[3], bytes[4], stream, bytes.sublist(9, length + 9)));
      bytes.removeRange(0, length + 9);
    }
    return frames;
  }
}

class _Capture extends EventListener {
  final requests = <HttpRequest>[];
  final responses = <HttpResponse>[];

  @override
  void onRequest(Channel channel, HttpRequest request) => requests.add(request);

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) => responses.add(response);
}

class _FixtureDeviceInfo extends DeviceInfoPlatform {
  final BaseDeviceInfo value;

  _FixtureDeviceInfo(this.value);

  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    if (io.Platform.isLinux) {
      return LinuxDeviceInfo(name: 'test', id: 'test', prettyName: 'test', machineId: 'resource-e2e');
    }
    if (io.Platform.isMacOS) {
      return MacOsDeviceInfo.fromMap({
        'computerName': 'test',
        'hostName': 'test',
        'arch': 'test',
        'model': 'test',
        'modelName': 'test',
        'kernelVersion': 'test',
        'osRelease': 'test',
        'majorVersion': 0,
        'minorVersion': 0,
        'patchVersion': 0,
        'activeCPUs': 1,
        'memorySize': 1024,
        'cpuFrequency': 1,
        'systemGUID': 'resource-e2e',
      });
    }
    return value;
  }
}

class _OriginRequest {
  final io.Socket socket;
  final String path;

  _OriginRequest(this.socket, this.path);

  Future<void> headers({String mime = 'video/mp4', int status = 200, int? length = 3, String extra = ''}) async {
    final phrase = status == 206
        ? 'Partial Content'
        : status == 404
            ? 'Not Found'
            : 'OK';
    socket.add(ascii.encode('HTTP/1.1 $status $phrase\r\nContent-Type: $mime\r\n'
        '${length == null ? '' : 'Content-Length: $length\r\n'}$extra'
        'Connection: close\r\n\r\n'));
    await socket.flush();
  }

  Future<void> body(List<int> bytes) async {
    socket.add(bytes);
    await socket.flush();
    await socket.close();
  }
}

/// A controlled origin with separate header/body writes and no external network.
class _HttpOrigin {
  final io.ServerSocket server;
  final sockets = <io.Socket>[];
  final received = <String, _OriginRequest>{};
  final waiting = <String, Completer<_OriginRequest>>{};
  int requestCount = 0;

  _HttpOrigin(this.server) {
    server.listen((socket) {
      sockets.add(socket);
      final bytes = <int>[];
      var handled = false;
      socket.listen((incoming) {
        if (handled) return;
        bytes.addAll(incoming);
        final wire = latin1.decode(bytes);
        if (!wire.contains('\r\n\r\n')) return;
        handled = true;
        final target = wire.split('\r\n').first.split(' ')[1];
        final uri = Uri.parse(target);
        final path = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
        final request = _OriginRequest(socket, path);
        requestCount++;
        received[path] = request;
        waiting.remove(path)?.complete(request);
      }, onError: (Object _) {});
    });
  }

  static Future<_HttpOrigin> start() async =>
      _HttpOrigin(await io.ServerSocket.bind(io.InternetAddress.loopbackIPv4, 0));

  int get port => server.port;

  Future<_OriginRequest> wait(String path) => received.containsKey(path)
      ? Future.value(received[path])
      : (waiting[path] ??= Completer<_OriginRequest>()).future.timeout(const Duration(seconds: 10));

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

Future<void> _eventually(Future<bool> Function() check) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for live proxy observation');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttpOverrides = io.HttpOverrides.current;
  final previousDeviceInfo = DeviceInfoPlatform.instance;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late io.Directory work;
  String? previousHome;
  late ProxyServer proxy;
  late _HttpOrigin origin;
  late _Capture capture;
  final manager = ResourceSnifferManager.instance;
  final clients = <io.HttpClient>[];
  final rawSockets = <io.Socket>[];

  setUpAll(() async {
    // Flutter widget-test bindings replace HttpClient with a 400 stub. This
    // suite intentionally exercises real loopback sockets instead.
    io.HttpOverrides.global = null;
    work = await io.Directory.systemTemp.createTemp('proxypin-resource-live-');
    previousHome = FileRead.userHome;
    FileRead.userHome = work.path;
    messenger.setMockMethodCallHandler(pathChannel, (call) async => work.path);
    // Verify isolation before any startup/configuration singleton is initialized.
    expect((await getApplicationSupportDirectory()).path, work.path);
    expect(await Paths.homePath(), work.path);
    DeviceInfoPlatform.instance = _FixtureDeviceInfo(
      WindowsDeviceInfo(
        computerName: 'test',
        numberOfCores: 1,
        systemMemoryInMegabytes: 1024,
        userName: 'test',
        majorVersion: 10,
        minorVersion: 0,
        buildNumber: 0,
        platformId: 2,
        csdVersion: '',
        servicePackMajor: 0,
        servicePackMinor: 0,
        suitMask: 0,
        productType: 1,
        reserved: 0,
        buildLab: '',
        buildLabEx: '',
        digitalProductId: Uint8List(0),
        displayVersion: '',
        editionId: '',
        installDate: DateTime.utc(2026),
        productId: '',
        productName: 'test',
        registeredOwner: '',
        releaseId: '',
        deviceId: 'resource-e2e',
      ),
    );
  });

  tearDownAll(() async {
    io.HttpOverrides.global = previousHttpOverrides;
    DeviceInfoPlatform.instance = previousDeviceInfo;
    FileRead.userHome = previousHome;
    messenger.setMockMethodCallHandler(pathChannel, null);
    await work.delete(recursive: true);
  });

  setUp(() async {
    origin = await _HttpOrigin.start();
    capture = _Capture();
    proxy = ProxyServer(Configuration.fromJson({
      'port': 0,
      'startup': false,
      'enableSsl': false,
      'enableSystemProxy': false,
      'enableSocks5': false,
      'enabledHttp2': true,
      'whitelist': {'enabled': false, 'list': <String>[]},
      'blacklist': {'enabled': false, 'list': <String>[]},
    }));
    proxy.addListener(capture);
    await proxy.start();
    await CertificateManager.initCAConfig();
    // On Windows startup owns the attachment; this also makes the fixture portable.
    manager.attach(proxy);
    await manager.handleCommand('resourceSnifferSetEnabled', {'enabled': true});
    await manager.handleCommand('resourceSnifferClear', {});
  });

  tearDown(() async {
    for (final client in clients) {
      client.close(force: true);
    }
    clients.clear();
    for (final socket in rawSockets) {
      socket.destroy();
    }
    rawSockets.clear();
    await proxy.stop();
    await origin.close();
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${origin.port}$path');

  Future<io.HttpClientResponse> request(String path) async {
    final client = io.HttpClient()..connectionTimeout = const Duration(seconds: 10);
    clients.add(client);
    final port = proxy.server!.serverSocket.port;
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    final request = await client.getUrl(url(path));
    request.headers.set('Referer', 'http://example.test/player');
    return await request.close().timeout(const Duration(seconds: 10));
  }

  Future<List<Map<String, dynamic>>> resources() async =>
      ((await manager.handleCommand('resourceSnifferExport', {}))['resources'] as List).cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> entry(String path) async {
    await _eventually(() async => (await resources()).any((entry) => entry['url'] == url(path).toString()));
    return (await resources()).singleWhere((entry) => entry['url'] == url(path).toString());
  }

  Future<void> complete(String path, {String mime = 'video/mp4', int status = 200, String extra = ''}) async {
    final responseFuture = request(path);
    final peer = await origin.wait(path);
    await peer.headers(mime: mime, status: status, extra: extra);
    await peer.body(ascii.encode('abc'));
    final response = await responseFuture;
    expect(response.statusCode, status);
    expect(await response.transform(ascii.decoder).join(), 'abc');
  }

  test('real HTTP/1 headers collect before body; forwarding, repeated URL and signed URL counts stay intact', () async {
    final responseFuture = request('/media?id=one');
    final peer = await origin.wait('/media?id=one');
    await peer.headers(mime: 'audio/mpeg');
    var resource = await entry('/media?id=one');
    expect(resource['kind'], 'audio');
    expect(resource['sizeBytes'], 3);
    expect(resource['referer'], 'http://example.test/player');
    expect(resource['hitCount'], 1);
    expect(capture.responses, isEmpty, reason: 'The body has not been sent by the origin');
    await peer.body(ascii.encode('abc'));
    final response = await responseFuture;
    expect(await response.transform(ascii.decoder).join(), 'abc');
    await _eventually(() async => capture.responses.length == 1);
    resource = await entry('/media?id=one');
    expect(resource['hitCount'], 1);
    origin.received.remove('/media?id=one');
    await complete('/media?id=one', mime: 'audio/mpeg');
    expect((await entry('/media?id=one'))['hitCount'], 2);
    await complete('/media?id=two', mime: 'audio/mpeg');
    expect(await resources(), hasLength(2));
    expect(origin.requestCount, 3, reason: 'Sniffing does not request the discovered links');
  });

  test('real FLV stream with unknown length is detected and byte-for-byte relayed', () async {
    final responseFuture = request('/live');
    final peer = await origin.wait('/live');
    await peer.headers(mime: 'video/x-flv', length: null);
    final resource = await entry('/live');
    expect(resource['kind'], 'video');
    expect(resource['sizeBytes'], isNull);
    final payload = [70, 76, 86, 1, 0, 128, 255, 13, 10];
    await peer.body(payload);
    final response = await responseFuture;
    final bytes = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    expect(bytes, payload);
    expect((await entry('/live'))['hitCount'], 1);
    expect(origin.requestCount, 1);
  });

  test('clear excludes an actual in-flight response, then new traffic is collected', () async {
    final responseFuture = request('/old.mp4');
    final peer = await origin.wait('/old.mp4');
    expect(capture.requests, hasLength(1));
    await manager.handleCommand('resourceSnifferClear', {});
    await peer.headers();
    await peer.body(ascii.encode('abc'));
    final response = await responseFuture;
    expect(await response.transform(ascii.decoder).join(), 'abc');
    expect(await resources(), isEmpty);
    final recognizedFuture = request('/recognized.mp4');
    final recognized = await origin.wait('/recognized.mp4');
    await recognized.headers();
    expect((await entry('/recognized.mp4'))['hitCount'], 1);
    await manager.handleCommand('resourceSnifferClear', {});
    await recognized.body(ascii.encode('abc'));
    expect(await (await recognizedFuture).transform(ascii.decoder).join(), 'abc');
    expect(await resources(), isEmpty, reason: 'A final callback cannot restore a resource cleared after its headers');
    await complete('/new.mp4');
    expect((await resources()).single['url'], url('/new.mp4').toString());
  });

  test('pause suppresses a real in-flight request across resume without breaking forwarding', () async {
    await manager.handleCommand('resourceSnifferSetEnabled', {'enabled': false});
    final responseFuture = request('/paused.mp4');
    final peer = await origin.wait('/paused.mp4');
    await manager.handleCommand('resourceSnifferSetEnabled', {'enabled': true});
    await peer.headers();
    await peer.body(ascii.encode('abc'));
    expect(await (await responseFuture).transform(ascii.decoder).join(), 'abc');
    expect(await resources(), isEmpty);
    await complete('/resumed.mp4');
    expect((await resources()).single['url'], url('/resumed.mp4').toString());
  });

  test('domain filtering keeps actual media traffic intact but excludes sniffer capture', () async {
    HostFilter.blacklist.load({
      'enabled': true,
      'list': [r'^127\.0\.0\.1$']
    });
    await complete('/filtered.mp4');
    expect(await resources(), isEmpty);
    expect(capture.requests, isEmpty);
    HostFilter.blacklist.load({'enabled': false, 'list': <String>[]});
    await complete('/visible.mp4');
    expect((await resources()).single['url'], url('/visible.mp4').toString());
  });

  test('real partial response uses full Content-Range size while errors and default images are excluded', () async {
    await complete('/part', status: 206, extra: 'Content-Range: bytes 4-6/1000\r\n');
    expect((await entry('/part'))['sizeBytes'], 1000);
    await complete('/error.mp4', status: 404);
    await complete('/photo.jpg', mime: 'image/jpeg');
    expect(await resources(), hasLength(1));
    expect(origin.requestCount, 3);
  });

  test('real proxy restarts retain resources and attach exactly one sniffer listener', () async {
    await complete('/before.mp4');
    await proxy.restart();
    await proxy.restart();
    expect(proxy.listeners.where((listener) => identical(listener, manager)), hasLength(1));
    expect((await resources()).single['url'], url('/before.mp4').toString());
    await complete('/after.mp4');
    expect(await resources(), hasLength(2));
    expect((await entry('/after.mp4'))['hitCount'], 1);
  });

  test('real h2c split HEADERS/CONTINUATION collect before DATA and preserve final bytes and counts', () async {
    final h2Origin = await io.ServerSocket.bind(io.InternetAddress.loopbackIPv4, 0);
    final upstreamReceived = Completer<io.Socket>();
    final peers = <io.Socket>[];
    h2Origin.listen((socket) {
      peers.add(socket);
      final prefix = <int>[];
      final frames = _FrameBuffer();
      final decoder = HPackDecoder();
      var started = false;
      socket.listen((bytes) {
        List<int> incoming = bytes;
        if (!started) {
          prefix.addAll(bytes);
          if (prefix.length < _preface.length) return;
          expect(prefix.sublist(0, _preface.length), ascii.encode(_preface));
          incoming = prefix.sublist(_preface.length);
          started = true;
          socket.add(_frame(4, 0, 0, []));
        }
        for (final (type, flags, stream, payload) in frames.add(incoming)) {
          if (type == 4 && flags == 0) socket.add(_frame(4, 1, 0, []));
          if (type == 1 && stream == 1 && !upstreamReceived.isCompleted) {
            final headers = {for (final header in decoder.decode(payload)) header.nameString: header.valueString};
            expect(headers[':method'], 'GET');
            expect(headers[':authority'], '127.0.0.1:${h2Origin.port}');
            expect(headers[':path'], '/playlist?id=live');
            upstreamReceived.complete(socket);
          }
        }
      }, onError: (Object _) {});
    });
    addTearDown(() async {
      for (final peer in peers) {
        peer.destroy();
      }
      await h2Origin.close();
    });
    final client = await io.Socket.connect(io.InternetAddress.loopbackIPv4, proxy.server!.serverSocket.port);
    rawSockets.add(client);
    final frames = _FrameBuffer();
    final body = <int>[];
    final finished = Completer<void>();
    client.listen((bytes) {
      for (final (type, flags, stream, payload) in frames.add(bytes)) {
        if (type == 4 && flags == 0) client.add(_frame(4, 1, 0, []));
        if (type == 0 && stream == 1) body.addAll(payload);
        if (stream == 1 && (type == 0 || type == 1) && flags & 1 != 0 && !finished.isCompleted) {
          finished.complete();
        }
      }
    });
    final headers = HPackEncoder().encode([
      Header.ascii(':method', 'GET'),
      Header.ascii(':scheme', 'http'),
      Header.ascii(':authority', '127.0.0.1:${h2Origin.port}'),
      Header.ascii(':path', '/playlist?id=live'),
    ]);
    client.add([...ascii.encode(_preface), ..._frame(4, 0, 0, []), ..._frame(1, 5, 1, headers)]);
    await client.flush();
    final peer = await upstreamReceived.future.timeout(const Duration(seconds: 10));
    final block = HPackEncoder().encode([
      Header.ascii(':status', '200'),
      Header.ascii('content-type', 'application/vnd.apple.mpegurl'),
      Header.ascii('content-length', '3'),
    ]);
    peer.add(_frame(1, 0, 1, block.sublist(0, 5)));
    await peer.flush();
    expect(await resources(), isEmpty);
    peer.add(_frame(9, 4, 1, block.sublist(5)));
    await peer.flush();
    await _eventually(() async => (await resources()).isNotEmpty);
    final resource = (await resources()).single;
    expect(resource['url'], 'http://127.0.0.1:${h2Origin.port}/playlist?id=live');
    expect(resource['kind'], 'hls');
    expect(resource['requestId'], capture.requests.single.requestId);
    expect(resource['hitCount'], 1);
    expect(finished.isCompleted, isFalse);
    expect(capture.responses, isEmpty);
    peer.add(_frame(0, 1, 1, ascii.encode('abc')));
    await peer.flush();
    await finished.future.timeout(const Duration(seconds: 10));
    expect(body, ascii.encode('abc'));
    expect((await resources()).single['hitCount'], 1);
    expect(capture.responses, hasLength(1));
    expect(peers, hasLength(1), reason: 'Sniffing does not create another upstream connection');
  });
}
