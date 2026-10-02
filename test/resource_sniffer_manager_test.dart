import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, HttpOverrides, HttpClient, HttpServer, InternetAddress;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/components/manager/resource_sniffer_manager.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_preview.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/process_info.dart';

class _UnusedChannel implements Channel {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late String configPath;
  late ResourceSnifferManager manager;
  late DateTime now;
  final channel = _UnusedChannel();
  late Map<String, dynamic> oldWhitelist;
  late Map<String, dynamic> oldBlacklist;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('resource_sniffer_test_');
    configPath = '${directory.path}${Platform.pathSeparator}resource_sniffer.json';
    now = DateTime.utc(2026, 10, 2);
    manager = ResourceSnifferManager(configPath: configPath, clock: () => now);
    oldWhitelist = HostFilter.whitelist.toJson();
    oldBlacklist = HostFilter.blacklist.toJson();
    HostFilter.whitelist.load({'enabled': false, 'list': <String>[]});
    HostFilter.blacklist.load({'enabled': false, 'list': <String>[]});
    await manager.initialize();
  });

  tearDown(() async {
    HostFilter.whitelist.load(oldWhitelist);
    HostFilter.blacklist.load(oldBlacklist);
    await directory.delete(recursive: true);
  });

  HttpRequest request(String url, {String? id, HttpMethod method = HttpMethod.get}) {
    final result = HttpRequest(method, url)..requestTime = now;
    if (id != null) result.requestId = id;
    return result;
  }

  HttpResponse response(HttpRequest? request, {int status = 200, String? mime, String? size, String? range}) {
    final result = HttpResponse(HttpStatus.valueOf(status))..request = request;
    if (mime != null) result.headers.contentType = mime;
    if (size != null) result.headers.set('Content-Length', size);
    if (range != null) result.headers.set('Content-Range', range);
    return result;
  }

  Future<List<Map<String, dynamic>>> resources({Map<String, dynamic> args = const {}}) async =>
      ((await manager.handleCommand('resourceSnifferExport', args))['resources'] as List).cast<Map<String, dynamic>>();

  test('headers recognize large/streaming media immediately; final enriches without another hit', () async {
    final req = request('https://cdn.example/live');
    req.headers.set('Referer', 'https://example/player');
    req.processInfo = ProcessInfo('browser.exe', 'Browser', 'browser.exe', os: 'windows');
    manager.onRequest(channel, req);
    final res = response(req, mime: 'video/x-flv', size: '900000000')..streamingBody = true;
    final context = ChannelContext();
    manager.onResponseHeaders(context, res);
    var entry = (await resources()).single;
    expect(entry['sizeBytes'], 900000000);
    expect(entry['kind'], 'video');
    expect(entry['referer'], 'https://example/player');
    expect(entry['processName'], 'Browser');
    expect(res.body, isNull);
    expect(entry['hitCount'], 1);
    now = now.add(const Duration(seconds: 3));
    manager.onResponse(context, res);
    entry = (await resources()).single;
    expect(entry['hitCount'], 1);
    expect(entry['lastSeen'], DateTime.utc(2026, 10, 2).toIso8601String());
    final second = request(req.requestUrl);
    manager.onRequest(channel, second);
    manager.onResponseHeaders(context, response(second, mime: 'video/x-flv'));
    expect((await resources()).single['hitCount'], 2);
  });

  test('requestId suppresses duplicates across request copies and signed URLs remain distinct', () async {
    final req = request('https://cdn.example/video.mp4?signature=one', id: 'same-request');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final copy = request(req.requestUrl, id: req.requestId);
    manager.onResponse(ChannelContext(), response(copy, mime: 'video/mp4', size: '999'));
    expect((await resources()).single['hitCount'], 1);
    expect((await resources()).single['sizeBytes'], 999);
    final different = request('https://cdn.example/video.mp4?signature=two');
    manager.onRequest(channel, different);
    manager.onResponse(ChannelContext(), response(different));
    expect(await resources(), hasLength(2));
  });

  test('supports final-only local mapping and HTTP/2 stream association without changing traffic', () async {
    final req = request('https://cdn.example/local')..body = [1, 2, 3];
    req.headers.set('X-Original', 'yes');
    manager.onRequest(channel, req);
    final context = ChannelContext()..currentRequest = req;
    final res = response(null, mime: 'audio/mpeg')..body = [4, 5, 6];
    final beforeRequest = req.toJson();
    final beforeResponse = res.toJson();
    manager.onResponse(context, res);
    expect((await resources()).single['sizeBytes'], 3);
    expect(req.toJson(), beforeRequest);
    expect(res.toJson(), beforeResponse);
    final h2 = request('https://cdn.example/h2.m3u8')..streamId = 3;
    context.putStreamRequest(3, h2);
    manager.onRequest(channel, h2);
    manager.onResponseHeaders(context, response(null)..streamId = 3);
    expect((await resources()).where((entry) => entry['kind'] == 'hls'), hasLength(1));
  });

  test('partial responses use Content-Range total and malformed/unknown sizes stay safe', () async {
    final context = ChannelContext();
    final partial = request('https://cdn.example/video.mp4');
    manager.onRequest(channel, partial);
    manager.onResponseHeaders(context, response(partial, status: 206, size: '100', range: 'bytes 0-99/4567'));
    expect((await resources()).single['sizeBytes'], 4567);
    final unknown = request('https://cdn.example/live.flv');
    manager.onRequest(channel, unknown);
    manager.onResponseHeaders(context, response(unknown, size: 'invalid'));
    expect((await resources()).firstWhere((entry) => entry['url'] == unknown.requestUrl)['sizeBytes'], isNull);
    final cached = request(partial.requestUrl);
    manager.onRequest(channel, cached);
    manager.onResponseHeaders(context, response(cached, status: 304));
    expect((await resources()).firstWhere((entry) => entry['url'] == partial.requestUrl)['sizeBytes'], 4567);
  });

  test('new 206 requests with an unknown or invalid total show an unknown size', () async {
    const url = 'https://cdn.example/partial.mp4';
    final context = ChannelContext();
    final unknown = request(url);
    manager.onRequest(channel, unknown);
    final fragment = response(unknown, status: 206, size: '100', range: 'bytes 0-99/*')..body = [1, 2, 3];
    manager.onResponseHeaders(context, fragment);
    manager.onResponse(context, fragment);
    expect((await resources()).single['sizeBytes'], isNull);

    now = now.add(const Duration(seconds: 1));
    final complete = request(url);
    manager.onRequest(channel, complete);
    manager.onResponseHeaders(context, response(complete, status: 206, size: '100', range: 'bytes 0-99/4567'));
    expect((await resources()).single['sizeBytes'], 4567);

    for (final range in [null, 'bytes 0-99/*', 'invalid', 'bytes 0-99/50', 'bytes 99-0/4567']) {
      now = now.add(const Duration(seconds: 1));
      final later = request(url);
      manager.onRequest(channel, later);
      final res = response(later, status: 206, size: '10', range: range)..body = [4, 5];
      manager.onResponseHeaders(context, res);
      manager.onResponse(context, res);
      expect((await resources()).single['sizeBytes'], isNull, reason: 'range: $range');
    }
  });

  test('ignores unassociated, CONNECT, 1xx, errors and filtered domains', () async {
    final context = ChannelContext();
    manager.onResponseHeaders(context, response(null, mime: 'video/mp4'));
    for (final status in [100, 103, 301, 404, 500]) {
      final req = request('https://cdn.example/$status.mp4');
      manager.onRequest(channel, req);
      manager.onResponseHeaders(context, response(req, status: status));
    }
    final connect = request('https://cdn.example/connect.mp4', method: HttpMethod.connect);
    manager.onRequest(channel, connect);
    manager.onResponseHeaders(context, response(connect));
    HostFilter.blacklist.load({
      'enabled': true,
      'list': [r'^blocked\.example$']
    });
    final blocked = request('https://blocked.example/file.mp4');
    manager.onRequest(channel, blocked);
    manager.onResponseHeaders(context, response(blocked));
    expect(await resources(), isEmpty);
    final success = request('https://cdn.example/file.mp4');
    manager.onRequest(channel, success);
    manager.onResponseHeaders(context, response(success));
    expect(await resources(), hasLength(1));
  });

  test('pause and image settings persist while collected resources remain session-only', () async {
    final initialFuture = manager.initialize();
    expect(identical(initialFuture, manager.initialize()), isTrue);
    await manager.handleCommand('resourceSnifferSetEnabled', {'enabled': false});
    final paused = request('https://cdn.example/paused.mp4');
    manager.onRequest(channel, paused);
    manager.onResponseHeaders(ChannelContext(), response(paused));
    expect(await resources(), isEmpty);
    await manager.handleCommand('resourceSnifferUpdateConfig', {
      'config': {'enabled': true, 'includeImages': true, 'rules': <dynamic>[]},
    });
    expect(manager.config.enabled, false);
    await manager.handleCommand('resourceSnifferSetEnabled', {'enabled': true});
    manager.onResponse(ChannelContext(), response(paused));
    expect(await resources(), isEmpty);
    final image = request('https://cdn.example/picture.jpg');
    manager.onRequest(channel, image);
    manager.onResponseHeaders(ChannelContext(), response(image));
    expect((await resources()).single['kind'], 'image');
    final reopened = ResourceSnifferManager(configPath: configPath);
    await reopened.initialize();
    expect(reopened.config.includeImages, isTrue);
    expect(reopened.config.enabled, isTrue);
    expect(reopened.resourceCount, 0);
    await reopened.handleCommand('resourceSnifferSetEnabled', {'enabled': false});
    final pausedRestart = ResourceSnifferManager(configPath: configPath);
    await pausedRestart.initialize();
    expect(pausedRestart.config.enabled, isFalse);
  });

  test('saving recognition settings preserves a different windows latest pause state on disk', () async {
    final stale = manager.config.toJson();
    await manager.handleCommand('resourceSnifferSetEnabled', {'enabled': false});
    stale['includeImages'] = true;
    await manager.handleCommand('resourceSnifferUpdateConfig', {'config': stale});
    expect(manager.config.enabled, false);
    expect(manager.config.includeImages, true);
    expect((jsonDecode(await File(configPath).readAsString()) as Map)['enabled'], false);
    final reopened = ResourceSnifferManager(configPath: configPath);
    await reopened.initialize();
    expect(reopened.config.enabled, false);
    expect(reopened.config.includeImages, true);
    await manager.handleCommand('resourceSnifferSetEnabled', {'enabled': true});
    await manager.handleCommand('resourceSnifferUpdateConfig', {
      'config': {'enabled': false, 'includeImages': false, 'rules': <dynamic>[]},
    });
    expect(manager.config.enabled, true);
  });

  test('304 without MIME inherits known classification and counts once at headers and final', () async {
    const url = 'https://cdn.example/resource';
    final first = request(url);
    first.headers.set('Referer', 'https://example/player');
    first.processInfo = ProcessInfo('browser.exe', 'Browser', 'browser.exe', os: 'windows');
    manager.onRequest(channel, first);
    manager.onResponseHeaders(ChannelContext(), response(first, mime: 'audio/mpeg', size: '100'));
    now = now.add(const Duration(seconds: 1));
    final cached = request(url);
    manager.onRequest(channel, cached);
    final notModified = response(cached, status: 304);
    manager.onResponseHeaders(ChannelContext(), notModified);
    manager.onResponse(ChannelContext(), notModified);
    final entry = (await resources()).single;
    expect(entry['kind'], 'audio');
    expect(entry['mimeType'], 'audio/mpeg');
    expect(entry['sizeBytes'], 100);
    expect(entry['statusCode'], 304);
    expect(entry['hitCount'], 2);
    expect(entry['lastSeen'], now.toIso8601String());
    expect(entry['referer'], isNull);
    expect(entry['processName'], isNull);
    expect(entry['contentRevision'], 0);
    final unknown = request('https://cdn.example/unknown');
    manager.onRequest(channel, unknown);
    manager.onResponseHeaders(ChannelContext(), response(unknown, status: 304));
    expect(await resources(), hasLength(1));
  });

  test('304 preserves MIME over URL suffix and attachment-only names with current settings', () async {
    final audio = request('https://cdn.example/video.mp4');
    manager.onRequest(channel, audio);
    manager.onResponseHeaders(ChannelContext(), response(audio, mime: 'audio/mpeg'));
    for (final mime in [null, '', '   ', ' ; charset=utf-8']) {
      final cachedAudio = request(audio.requestUrl);
      manager.onRequest(channel, cachedAudio);
      manager.onResponseHeaders(ChannelContext(), response(cachedAudio, status: 304, mime: mime));
      final entry = (await resources()).single;
      expect(entry['kind'], 'audio', reason: 'Content-Type: $mime');
      expect(entry['mimeType'], 'audio/mpeg', reason: 'Content-Type: $mime');
      expect(entry['contentRevision'], 0);
    }

    final attachment = request('https://cdn.example/download');
    manager.onRequest(channel, attachment);
    final file = response(attachment, mime: 'application/octet-stream');
    file.headers.set('Content-Disposition', 'attachment; filename="clip.webm"');
    manager.onResponseHeaders(ChannelContext(), file);
    final cachedFile = request(attachment.requestUrl);
    manager.onRequest(channel, cachedFile);
    manager.onResponseHeaders(ChannelContext(), response(cachedFile, status: 304));
    final attached = (await resources()).firstWhere((entry) => entry['url'] == attachment.requestUrl);
    expect(attached['fileName'], 'clip.webm');
    expect(attached['kind'], 'video');
    expect(attached['hitCount'], 2);

    await manager.handleCommand('resourceSnifferUpdateConfig', {
      'config': {'includeImages': true},
    });
    final image = request('https://cdn.example/image');
    manager.onRequest(channel, image);
    manager.onResponseHeaders(ChannelContext(), response(image, mime: 'image/png'));
    await manager.handleCommand('resourceSnifferUpdateConfig', {
      'config': {'includeImages': false},
    });
    final cachedImage = request(image.requestUrl);
    manager.onRequest(channel, cachedImage);
    manager.onResponseHeaders(ChannelContext(), response(cachedImage, status: 304));
    expect((await resources()).firstWhere((entry) => entry['url'] == image.requestUrl)['hitCount'], 1);

    HostFilter.blacklist.load({
      'enabled': true,
      'list': [r'^cdn\.example$']
    });
    final blocked = request(audio.requestUrl);
    manager.onRequest(channel, blocked);
    manager.onResponseHeaders(ChannelContext(), response(blocked, status: 304));
    expect((await resources()).firstWhere((entry) => entry['url'] == audio.requestUrl)['hitCount'], 5);
  });

  test('same-request final without headers keeps the MIME and attachment classification', () async {
    final audio = request('https://cdn.example/video.mp4');
    manager.onRequest(channel, audio);
    manager.onResponseHeaders(ChannelContext(), response(audio, mime: 'audio/mpeg'));
    manager.onResponse(ChannelContext(), response(audio)..body = [1, 2]);
    final audioEntry = (await resources()).single;
    expect(audioEntry['kind'], 'audio');
    expect(audioEntry['mimeType'], 'audio/mpeg');
    expect(audioEntry['sizeBytes'], 2);
    expect(audioEntry['hitCount'], 1);

    final attachment = request('https://cdn.example/download');
    manager.onRequest(channel, attachment);
    final headers = response(attachment, mime: 'application/octet-stream');
    headers.headers.set('Content-Disposition', 'attachment; filename="clip.webm"');
    manager.onResponseHeaders(ChannelContext(), headers);
    manager.onResponse(ChannelContext(), response(attachment)..body = [3, 4, 5]);
    final file = (await resources()).firstWhere((entry) => entry['url'] == attachment.requestUrl);
    expect(file['kind'], 'video');
    expect(file['fileName'], 'clip.webm');
    expect(file['sizeBytes'], 3);
    expect(file['hitCount'], 1);
  });

  test('new successful response does not inherit old size or request metadata', () async {
    final first = request('https://cdn.example/live.flv');
    first.headers.set('Referer', 'https://example/player');
    first.processInfo = ProcessInfo('browser.exe', 'Browser', 'browser.exe', os: 'windows');
    manager.onRequest(channel, first);
    manager.onResponseHeaders(ChannelContext(), response(first, mime: 'video/x-flv', size: '100'));
    // Equal timestamps are common on busy connections. A late final from the
    // first request must not recover its old headers after the second begins.
    final fresh = request(first.requestUrl);
    manager.onRequest(channel, fresh);
    final streaming = response(fresh, mime: 'video/x-flv')..streamingBody = true;
    manager.onResponseHeaders(ChannelContext(), streaming);
    manager.onResponse(ChannelContext(), response(first, mime: 'video/x-flv', size: '100'));
    manager.onResponse(ChannelContext(), streaming);
    final entry = (await resources()).single;
    expect(entry['sizeBytes'], isNull);
    expect(entry['referer'], isNull);
    expect(entry['processName'], isNull);
    expect(entry['requestId'], fresh.requestId);
    expect(entry['hitCount'], 2);
    expect(entry['contentRevision'], 1);
  });

  test('clear excludes existing in-flight requests and admits new requests', () async {
    final old = request('https://cdn.example/old.mp4');
    final pending = request('https://cdn.example/pending.mp4');
    final unobserved = request('https://cdn.example/unobserved.mp4');
    manager.onRequest(channel, old);
    manager.onRequest(channel, pending);
    manager.onResponseHeaders(ChannelContext(), response(old));
    now = now.add(const Duration(seconds: 1));
    await manager.handleCommand('resourceSnifferClear', {});
    manager.onResponse(ChannelContext(), response(old));
    manager.onResponseHeaders(ChannelContext(), response(pending));
    manager.onResponseHeaders(ChannelContext(), response(unobserved));
    final copiedPending = request(pending.requestUrl, id: pending.requestId);
    manager.onResponseHeaders(ChannelContext(), response(copiedPending));
    expect(await resources(), isEmpty);
    // Request and clear clocks can share a tick; onRequest provides the generation boundary.
    final fresh = request('https://cdn.example/new.mp4');
    manager.onRequest(channel, fresh);
    manager.onResponseHeaders(ChannelContext(), response(fresh));
    expect((await resources()).single['url'], fresh.requestUrl);
  });

  test('query paginates and checks revisions; export includes all filtered or selected resources', () async {
    for (var index = 0; index < 205; index++) {
      now = now.add(const Duration(seconds: 1));
      final req = request('https://${index.isEven ? 'a' : 'b'}.example/movie$index.mp4');
      manager.onRequest(channel, req);
      manager.onResponseHeaders(ChannelContext(), response(req));
    }
    final first = await manager.handleCommand('resourceSnifferQuery', {'offset': 0, 'limit': 1000});
    expect(first['total'], 205);
    expect(first['resources'], hasLength(100));
    expect(first['hosts'], ['a.example', 'b.example']);
    final second = await manager.handleCommand('resourceSnifferQuery', {'offset': 200});
    expect(second['resources'], hasLength(5));
    final unchanged = await manager.handleCommand('resourceSnifferQuery', {'knownRevision': first['revision']});
    expect(unchanged['unchanged'], isTrue);
    expect(unchanged.containsKey('resources'), isFalse);
    expect(await resources(), hasLength(205));
    expect(await resources(args: {'host': 'a.example', 'kind': 'video'}), hasLength(103));
    final selected = (first['resources'] as List).first as Map;
    expect(
        await resources(args: {
          'ids': [selected['id']]
        }),
        hasLength(1));
    expect(await resources(args: {'keyword': 'movie204'}), hasLength(1));
  });

  test('invalid configurations leave active settings and persisted JSON unchanged', () async {
    final beforeFile = await File(configPath).readAsString();
    final beforeConfig = manager.config.toJson();
    final beforeRevision = manager.revision;
    await expectLater(
        manager.handleCommand('resourceSnifferUpdateConfig', {
          'config': {
            'enabled': false,
            'includeImages': true,
            'rules': [
              {'id': 'invalid', 'type': 'urlRegex', 'pattern': '[', 'kind': 'video', 'enabled': true},
            ]
          },
        }),
        throwsFormatException);
    expect(manager.config.toJson(), beforeConfig);
    expect(manager.revision, beforeRevision);
    expect(await File(configPath).readAsString(), beforeFile);
    await manager.handleCommand('resourceSnifferUpdateConfig', {
      'config': {
        'enabled': true,
        'includeImages': false,
        'rules': [
          {'id': 'download', 'type': 'urlRegex', 'pattern': '/download', 'kind': 'video', 'enabled': true},
        ]
      },
    });
    final req = request('https://cdn.example/download');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    expect((await resources()).single['matchReason'], 'custom:urlRegex:/download');
    expect(jsonDecode(await File(configPath).readAsString()), manager.config.toJson());
  });

  test('unreadable settings use safe defaults and malformed traffic does not throw', () async {
    await File(configPath).writeAsString('{bad json');
    final bad = ResourceSnifferManager(configPath: configPath);
    await expectLater(bad.initialize(), completes);
    expect(bad.config.enabled, isTrue);
    final malformed = request('not a valid URL')..headers.set('Referer', 'test');
    expect(() => bad.onResponseHeaders(ChannelContext(), response(malformed, mime: 'video/mp4')), returnsNormally);
    expect(bad.resourceCount, 0);
  });

  test('attach is idempotent across server changes and does not clear captured metadata', () async {
    final first = ProxyServer(Configuration.fromJson({'enableSystemProxy': false}));
    final second = ProxyServer(Configuration.fromJson({'enableSystemProxy': false}));
    manager.attach(first);
    manager.attach(first);
    expect(first.listeners.where((listener) => identical(listener, manager)), hasLength(1));
    final req = request('https://cdn.example/retained.mp4');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    manager.attach(second);
    manager.attach(second);
    expect(first.listeners.contains(manager), isFalse);
    expect(second.listeners.where((listener) => identical(listener, manager)), hasLength(1));
    expect(await resources(), hasLength(1));
  });

  test('the default 2000-entry bound and late final protection apply to manager collection', () async {
    final capped = ResourceSnifferManager(configPath: configPath, clock: () => now);
    await capped.initialize();
    final first = request('https://cdn.example/first.mp4');
    capped.onRequest(channel, first);
    capped.onResponseHeaders(ChannelContext(), response(first));
    for (var index = 0; index < 2000; index++) {
      now = now.add(const Duration(seconds: 1));
      final req = request('https://cdn.example/$index.mp4');
      capped.onRequest(channel, req);
      capped.onResponseHeaders(ChannelContext(), response(req));
    }
    expect(capped.resourceCount, 2000);
    capped.onResponse(ChannelContext(), response(first));
    final exported = await capped.handleCommand('resourceSnifferExport', {'keyword': 'first.mp4'});
    expect(exported['resources'], isEmpty);
  });

  test('explicit preview enriches query/export and leaves hit count and saved config unchanged', () async {
    final png = Uint8List.fromList([137, 80, 78, 71]);
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (_) async => {
              'imageBytes': png,
              'width': 1920,
              'height': 1080,
              'durationMs': 9000,
              'codec': 'H264',
              'frameRate': 30,
            });
    await manager.initialize();
    final saved = await File(configPath).readAsString();
    final req = request('https://cdn.example/movie.mp4?signature=private');
    req.headers.set('Authorization', 'Bearer secret');
    req.headers.set('Cookie', 'token=private');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final before = (await resources()).single;
    final beforeRevision = manager.revision;
    final result = await manager.handleCommand('resourceSnifferPreview', {'id': before['id']});
    expect((result['preview'] as Map)['imageBase64'], base64Encode(png));
    final entry = (await resources()).single;
    expect((entry['preview'] as Map)['width'], 1920);
    expect((entry['preview'] as Map).containsKey('imageBase64'), false);
    expect(entry['hitCount'], 1);
    expect(entry['firstSeen'], before['firstSeen']);
    expect(entry['lastSeen'], before['lastSeen']);
    expect(entry['method'], 'GET');
    expect(manager.revision, beforeRevision + 1);
    expect(jsonEncode(entry), isNot(contains('Bearer secret')));
    expect(jsonEncode(entry), isNot(contains('token=private')));
    expect(await File(configPath).readAsString(), saved);
    final cachedRevision = manager.revision;
    await manager.handleCommand('resourceSnifferPreview', {'id': before['id']});
    expect(manager.revision, cachedRevision);
    final query = await manager.handleCommand('resourceSnifferQuery', {});
    expect(query['collectionGeneration'], 0);
    expect(((query['resources'] as List).single as Map)['preview'], entry['preview']);
  });

  test('content changes invalidate previews while unchanged finals and 304 keep the cache', () async {
    var decodes = 0;
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (_) async => {
              'width': 320,
              'height': 240,
              'codec': ++decodes == 1 ? 'H264' : 'MP3',
            });
    await manager.initialize();
    const url = 'https://cdn.example/media';
    final first = request(url);
    manager.onRequest(channel, first);
    final firstResponse = response(first, mime: 'video/mp4', size: '100')
      ..headers.set('ETag', 'v1')
      ..headers.set('Last-Modified', 'Thu, 01 Oct 2026 00:00:00 GMT');
    manager.onResponseHeaders(ChannelContext(), firstResponse);
    final id = (await resources()).single['id'];
    var preview = await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect((preview['preview'] as Map)['codec'], 'H264');
    expect(preview['contentRevision'], 0);
    manager.onResponse(ChannelContext(), response(first));
    expect((await resources()).single['contentRevision'], 0);
    await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect(decodes, 1);

    now = now.add(const Duration(seconds: 1));
    final cached = request(url);
    manager.onRequest(channel, cached);
    manager.onResponseHeaders(ChannelContext(), response(cached, status: 304));
    expect((await resources()).single.containsKey('preview'), true);
    await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect(decodes, 1);

    now = now.add(const Duration(seconds: 1));
    final changed = request(url);
    manager.onRequest(channel, changed);
    manager.onResponseHeaders(ChannelContext(), response(changed, mime: 'audio/mpeg', size: '200'));
    final fresh = (await resources()).single;
    expect(fresh['id'], id);
    expect(fresh['kind'], 'audio');
    expect(fresh['contentRevision'], 1);
    expect(fresh.containsKey('preview'), false);
    preview = await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect(decodes, 2);
    expect(preview['contentRevision'], 1);
    expect((preview['preview'] as Map)['codec'], 'MP3');
  });

  test('size and validator changes individually invalidate cached previews; method changes reject playback', () async {
    var decodes = 0;
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (_) async => {'width': 320, 'height': 240, 'codec': 'codec-${++decodes}'});
    await manager.initialize();
    const url = 'https://cdn.example/video.mp4';
    Future<Map<String, dynamic>> capture(
        {String size = '100',
        String etag = 'v1',
        String modified = 'date-1',
        HttpMethod method = HttpMethod.get}) async {
      now = now.add(const Duration(seconds: 1));
      final req = request(url, method: method);
      manager.onRequest(channel, req);
      final res = response(req, mime: 'video/mp4', size: size)
        ..headers.set('ETag', etag)
        ..headers.set('Last-Modified', modified);
      manager.onResponseHeaders(ChannelContext(), res);
      return (await resources()).single;
    }

    final first = await capture();
    final id = first['id'];
    await manager.handleCommand('resourceSnifferPreview', {'id': id});
    final unchanged = await capture();
    expect(unchanged['contentRevision'], 0);
    expect(unchanged.containsKey('preview'), true);
    await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect(decodes, 1);
    var changed = await capture(size: '200');
    expect(changed['contentRevision'], 1);
    expect(changed.containsKey('preview'), false);
    await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect(decodes, 2);
    changed = await capture(size: '200', etag: 'v2');
    expect(changed['contentRevision'], 2);
    expect(changed.containsKey('preview'), false);
    await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect(decodes, 3);
    changed = await capture(size: '200', etag: 'v2', modified: 'date-2');
    expect(changed['contentRevision'], 3);
    expect(changed.containsKey('preview'), false);
    await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect(decodes, 4);
    changed = await capture(size: '200', etag: 'v2', modified: 'date-2', method: HttpMethod.post);
    expect(changed['contentRevision'], 4);
    expect(changed.containsKey('preview'), false);
    expect((await manager.handleCommand('resourceSnifferPreview', {'id': id}))['code'], 'unsupportedMethod');
    expect(decodes, 4);
  });

  test('changed content cancels its in-flight preview and cannot publish a late result', () async {
    final started = Completer<void>();
    final decoder = Completer<Map<String, dynamic>>();
    var decodes = 0;
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (_) {
          decodes++;
          if (decodes > 1) return Future.value({'width': 640, 'height': 480, 'codec': 'new'});
          started.complete();
          return decoder.future;
        });
    await manager.initialize();
    final old = request('https://cdn.example/video.mp4');
    manager.onRequest(channel, old);
    manager.onResponseHeaders(ChannelContext(), response(old, mime: 'video/mp4', size: '100'));
    final id = (await resources()).single['id'];
    final pending = manager.handleCommand('resourceSnifferPreview', {'id': id});
    await started.future;
    now = now.add(const Duration(seconds: 1));
    final latest = request(old.requestUrl);
    manager.onRequest(channel, latest);
    manager.onResponseHeaders(ChannelContext(), response(latest, mime: 'video/mp4', size: '200'));
    expect((await pending)['code'], 'cancelled');
    decoder.complete({'width': 320, 'height': 240, 'codec': 'old'});
    await Future<void>.delayed(Duration.zero);
    final entry = (await resources()).single;
    expect(entry['contentRevision'], 1);
    expect(entry.containsKey('preview'), false);
    final result = await manager.handleCommand('resourceSnifferPreview', {'id': id});
    expect((result['preview'] as Map)['codec'], 'new');
    expect(result['contentRevision'], 1);
    expect(decodes, 2);
  });

  test('latest request headers authenticate the direct preview but never enter IPC metadata', () async {
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <Map<String, String?>>[];
    origin.listen((request) async {
      received.add({
        'authorization': request.headers.value('authorization'),
        'cookie': request.headers.value('cookie'),
        'referer': request.headers.value('referer'),
        'range': request.headers.value('range'),
      });
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    try {
      manager = ResourceSnifferManager(
          configPath: configPath,
          clock: () => now,
          mediaDecoder: (url) async {
            final client = HttpClient()..findProxy = (_) => 'DIRECT';
            try {
              final incoming = await (await client.getUrl(url)).close();
              await incoming.drain<void>();
              return {'width': 320, 'height': 240};
            } finally {
              client.close(force: true);
            }
          });
      final first = request('http://127.0.0.1:${origin.port}/private.mp4');
      first.headers.set('Authorization', 'Bearer old');
      manager.onRequest(channel, first);
      manager.onResponseHeaders(ChannelContext(), response(first));
      now = now.add(const Duration(seconds: 1));
      final latest = request(first.requestUrl);
      latest.headers.set('Authorization', 'Bearer latest');
      latest.headers.set('Cookie', 'token=latest');
      latest.headers.set('Referer', 'https://player.example/');
      manager.onRequest(channel, latest);
      manager.onResponseHeaders(ChannelContext(), response(latest));
      manager.onResponse(ChannelContext(), response(first));
      expect(received, isEmpty);
      final entry = (await resources()).single;
      final result = await manager.handleCommand('resourceSnifferPreview', {'id': entry['id']});
      expect(result.containsKey('error'), false);
      expect(received.single['authorization'], 'Bearer latest');
      expect(received.single['cookie'], 'token=latest');
      expect(received.single['referer'], 'https://player.example/');
      expect((await resources()).single['hitCount'], 2);
      expect(jsonEncode(await resources()), isNot(contains('Bearer latest')));
    } finally {
      await origin.close(force: true);
      HttpOverrides.global = oldOverrides;
    }
  });

  test('cancel bypasses the mutation queue and clears a pending decoder without metadata', () async {
    final started = Completer<void>();
    final decoder = Completer<Map<String, dynamic>>();
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (_) {
          started.complete();
          return decoder.future;
        });
    final req = request('https://cdn.example/movie.mp4');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final id = (await resources()).single['id'];
    final pending = manager.handleCommand('resourceSnifferPreview', {'id': id});
    await started.future;
    expect(await manager.handleCommand('resourceSnifferCancelPreview', {'id': id}), {'cancelled': true});
    expect((await pending)['code'], 'cancelled');
    decoder.complete({'width': 1920, 'height': 1080});
    await Future<void>.delayed(Duration.zero);
    expect((await resources()).single.containsKey('preview'), false);
  });

  test('clear increments collection generation, cancels preview and rejects its late result', () async {
    final started = Completer<void>();
    final decoder = Completer<Map<String, dynamic>>();
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (_) {
          started.complete();
          return decoder.future;
        });
    final req = request('https://cdn.example/movie.mp4');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final id = (await resources()).single['id'];
    final pending = manager.handleCommand('resourceSnifferPreview', {'id': id});
    await started.future;
    await manager.handleCommand('resourceSnifferClear', {});
    expect((await pending)['code'], 'cancelled');
    decoder.complete({'width': 1920, 'height': 1080});
    await Future<void>.delayed(Duration.zero);
    expect(await resources(), isEmpty);
    final query = await manager.handleCommand('resourceSnifferQuery', {'knownRevision': manager.revision});
    expect(query['collectionGeneration'], 1);
    expect(query['unchanged'], true);
    expect((await manager.handleCommand('resourceSnifferPreview', {'id': id}))['code'], 'notFound');
  });

  test('resource eviction cancels its pending preview and removes private state', () async {
    final started = Completer<void>();
    final decoder = Completer<Map<String, dynamic>>();
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        maxEntries: 1,
        mediaDecoder: (_) {
          started.complete();
          return decoder.future;
        });
    final req = request('https://cdn.example/old.mp4');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final id = (await resources()).single['id'];
    final pending = manager.handleCommand('resourceSnifferPreview', {'id': id});
    await started.future;
    now = now.add(const Duration(seconds: 1));
    final fresh = request('https://cdn.example/new.mp4');
    manager.onRequest(channel, fresh);
    manager.onResponseHeaders(ChannelContext(), response(fresh));
    expect((await pending)['code'], 'cancelled');
    decoder.complete({'width': 1920});
    expect((await resources()).single['url'], fresh.requestUrl);
    expect((await manager.handleCommand('resourceSnifferPreview', {'id': id}))['code'], 'notFound');
  });

  test('captured POST resources cannot be replayed by preview', () async {
    var decoded = false;
    manager = ResourceSnifferManager(
        configPath: configPath,
        mediaDecoder: (_) async {
          decoded = true;
          return {};
        });
    final req = request('https://cdn.example/movie.mp4', method: HttpMethod.post);
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final entry = (await resources()).single;
    expect(entry['method'], 'POST');
    expect((await manager.handleCommand('resourceSnifferPreview', {'id': entry['id']}))['code'], 'unsupportedMethod');
    expect(decoded, false);
  });

  test('native loopback bridge requests do not appear as captured resources even after completion', () async {
    late Uri bridge;
    final started = Completer<void>();
    final decoder = Completer<Map<String, dynamic>>();
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (url) {
          bridge = url;
          started.complete();
          return decoder.future;
        });
    final req = request('https://cdn.example/movie.mp4');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final id = (await resources()).single['id'];
    final pending = manager.handleCommand('resourceSnifferPreview', {'id': id});
    await started.future;
    final own = request(bridge.toString());
    manager.onRequest(channel, own);
    manager.onResponseHeaders(ChannelContext(), response(own, mime: 'video/mp4'));
    decoder.complete({'width': 320, 'height': 240});
    await pending;
    manager.onResponse(ChannelContext(), response(own, mime: 'video/mp4'));
    final laterOwn = request(bridge.toString());
    manager.onRequest(channel, laterOwn);
    manager.onResponseHeaders(ChannelContext(), response(laterOwn, mime: 'video/mp4'));
    final queryOwn = request(bridge.replace(query: 'decoder=seek').toString());
    manager.onRequest(channel, queryOwn);
    manager.onResponseHeaders(ChannelContext(), response(queryOwn, mime: 'video/mp4'));
    expect(manager.resourceCount, 1);
    expect((await resources()).single['hitCount'], 1);
  });

  test('failed preview exposes only safe diagnostics and never adds them to exports or saved settings', () async {
    manager = ResourceSnifferManager(
        configPath: configPath,
        clock: () => now,
        mediaDecoder: (_) async {
          throw const ResourcePreviewException('decodeFailed', 'The media could not be decoded', diagnostics: {
            'stage': 'sourceOpen',
            'nativeHRESULT': '0xc00d36c4',
            'httpStatus': 206,
            'url': 'https://cdn.example/?signature=secret',
            'headers': {'Cookie': 'private=secret'},
          });
        });
    await manager.initialize();
    final saved = await File(configPath).readAsString();
    final req = request('https://cdn.example/movie.mp4');
    req.headers.set('Cookie', 'private=secret');
    manager.onRequest(channel, req);
    manager.onResponseHeaders(ChannelContext(), response(req));
    final entry = (await resources()).single;
    final revision = manager.revision;
    final result = await manager.handleCommand('resourceSnifferPreview', {'id': entry['id']});
    expect(result['code'], 'decodeFailed');
    expect(result['diagnostics'], {'stage': 'sourceOpen', 'httpStatus': 206, 'nativeHRESULT': '0xC00D36C4'});
    expect(jsonEncode(result), isNot(contains('secret')));
    expect((await resources()).single.containsKey('diagnostics'), false);
    expect((await resources()).single.containsKey('preview'), false);
    expect((await resources()).single['hitCount'], 1);
    expect(manager.revision, revision);
    expect(await File(configPath).readAsString(), saved);
  });
}
