import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_sniffer.dart';

void main() {
  final classifier = ResourceClassifier();
  ResourceMatch? classify(String url, {String? mime, String? disposition, ResourceSnifferConfig? config}) =>
      classifier.classify(
        config: config ?? ResourceSnifferConfig(),
        url: url,
        mimeType: mime,
        contentDisposition: disposition,
      );

  group('resource classification', () {
    test('recognizes media and manifests with query parameters', () {
      final samples = {
        'track.mp3': ResourceKind.audio,
        'track.FLAC': ResourceKind.audio,
        'movie.mp4': ResourceKind.video,
        'live.flv': ResourceKind.video,
        'segment.ts': ResourceKind.video,
        'stream.m3u8': ResourceKind.hls,
        'manifest.mpd': ResourceKind.dash,
      };
      for (final sample in samples.entries) {
        final match = classify('https://cdn.example/${sample.key}?token=abc&expires=99');
        expect(match?.kind, sample.value, reason: sample.key);
        expect(match?.fileName, sample.key);
      }
    });

    test('recognizes MIME-only URLs and manifest MIME before audio wildcard', () {
      final samples = {
        'audio/mpeg; charset=utf-8': ResourceKind.audio,
        'video/mp4': ResourceKind.video,
        'video/x-flv': ResourceKind.video,
        'application/x-flv': ResourceKind.video,
        'application/vnd.apple.mpegurl': ResourceKind.hls,
        'audio/x-mpegurl': ResourceKind.hls,
        'application/dash+xml': ResourceKind.dash,
      };
      for (final sample in samples.entries) {
        final match = classify('https://cdn.example/resource?id=1', mime: sample.key);
        expect(match?.kind, sample.value, reason: sample.key);
        expect(match?.reason, startsWith('mime:'));
      }
    });

    test('image recognition is opt-in for both MIME and extensions', () {
      expect(classify('https://cdn.example/image.png'), isNull);
      expect(classify('https://cdn.example/image', mime: 'image/webp'), isNull);
      final config = ResourceSnifferConfig(includeImages: true);
      expect(classify('https://cdn.example/image.png', config: config)?.kind, ResourceKind.image);
      expect(classify('https://cdn.example/image', mime: 'image/webp', config: config)?.kind, ResourceKind.image);
    });

    test('uses attachment and RFC 5987 file names and removes directory segments', () {
      final attachment = classify('https://cdn.example/download',
          mime: 'application/octet-stream', disposition: 'attachment; filename="folder/song.mp3"');
      expect(attachment?.fileName, 'song.mp3');
      expect(attachment?.kind, ResourceKind.audio);
      expect(attachment?.reason, 'filename:mp3');
      final extended = classify('https://cdn.example/download',
          disposition: "attachment; filename=bad.txt; filename*=UTF-8''%E6%B5%8B%E8%AF%95.mp4");
      expect(extended?.fileName, '测试.mp4');
      expect(extended?.kind, ResourceKind.video);
    });

    test('rejects HTML/JSON/code false positives and non-HTTP URLs', () {
      for (final mime in [
        'text/html',
        'application/xhtml+xml',
        'application/json',
        'application/problem+json',
        'application/javascript',
        'text/css'
      ]) {
        expect(classify('https://cdn.example/video.mp4', mime: mime), isNull, reason: mime);
      }
      expect(classify('file:///video.mp4'), isNull);
      expect(classify('https://cdn.example/unknown'), isNull);
      expect(classify('https://cdn.example/api?file=video.mp4'), isNull);
    });

    test('custom rules are ordered, disabled rules are skipped and fallback remains', () {
      final config = ResourceSnifferConfig(rules: [
        ResourceSnifferRule(
            id: 'disabled',
            type: ResourceRuleType.urlRegex,
            pattern: 'example',
            kind: ResourceKind.other,
            enabled: false),
        ResourceSnifferRule(
            id: 'first', type: ResourceRuleType.extension, pattern: '.mp4,webm', kind: ResourceKind.audio),
        ResourceSnifferRule(id: 'second', type: ResourceRuleType.mime, pattern: 'video/*', kind: ResourceKind.other),
      ]);
      expect(classify('https://cdn.example/movie.MP4', mime: 'video/mp4', config: config)?.kind, ResourceKind.audio);
      expect(classify('https://cdn.example/noext', mime: 'VIDEO/MP4', config: config)?.kind, ResourceKind.other);
      expect(classify('https://cdn.example/track.mp3', config: config)?.kind, ResourceKind.audio);
      final regex = ResourceSnifferConfig(rules: [
        ResourceSnifferRule(
            id: 'url', type: ResourceRuleType.urlRegex, pattern: r'/download\?id=\d+', kind: ResourceKind.video),
      ]);
      expect(classify('https://cdn.example/download?id=22', mime: 'application/json', config: regex)?.kind,
          ResourceKind.video);
      expect(classify('https://cdn.example/DOWNLOAD?id=22', config: regex), isNull);
    });

    test('configuration validates regular expressions, rule types and duplicate ids', () {
      expect(
        () => ResourceSnifferRule(
            id: 'empty', type: ResourceRuleType.extension, pattern: ',; ', kind: ResourceKind.video),
        throwsFormatException,
      );
      expect(
          () => ResourceSnifferRule(id: 'x', type: ResourceRuleType.urlRegex, pattern: '[', kind: ResourceKind.video),
          throwsFormatException);
      expect(() => ResourceSnifferConfig.fromJson({'enabled': 'yes'}), throwsFormatException);
      expect(
          () => ResourceSnifferConfig.fromJson({
                'rules': [
                  {'id': 'x', 'type': 'bad', 'pattern': 'x', 'kind': 'video'}
                ]
              }),
          throwsFormatException);
      final rule =
          ResourceSnifferRule(id: 'x', type: ResourceRuleType.mime, pattern: 'audio/*', kind: ResourceKind.audio);
      expect(
          () => ResourceSnifferConfig.fromJson({
                'rules': [rule.toJson(), rule.toJson()]
              }),
          throwsFormatException);
      final original = ResourceSnifferConfig(enabled: false, includeImages: true, rules: [rule]);
      expect(ResourceSnifferConfig.fromJson(original.toJson()).toJson(), original.toJson());
      expect(original.copyWith(enabled: true).includeImages, isTrue);
    });
  });

  ResourceMetadata metadata(String url, DateTime seenAt,
          {String requestId = 'r',
          String method = 'GET',
          int status = 200,
          int? size,
          String? mime,
          String? referer,
          String? processName,
          String? etag,
          String? lastModified}) =>
      ResourceMetadata(
          url: url,
          method: method,
          fileName: Uri.parse(url).path.split('/').last,
          kind: ResourceKind.video,
          mimeType: mime,
          sizeBytes: size,
          statusCode: status,
          host: Uri.parse(url).host,
          requestId: requestId,
          referer: referer,
          processName: processName,
          etag: etag,
          lastModified: lastModified,
          matchReason: 'extension:mp4',
          seenAt: seenAt);

  group('bounded metadata store', () {
    test('new successes replace missing metadata but same-request finals supplement headers', () {
      final store = ResourceSnifferStore();
      final time = DateTime.utc(2026, 10, 2);
      const url = 'https://cdn.example/video.mp4';
      store.record(
          metadata(url, time,
              size: 100,
              mime: 'video/mp4',
              referer: 'https://example/player',
              processName: 'Browser',
              etag: 'v1',
              lastModified: 'Thu, 01 Oct 2026 00:00:00 GMT'),
          countHit: true);
      store.record(metadata(url, time), countHit: false);
      final same = store.findByUrl(url)!;
      expect(same.metadata.sizeBytes, 100);
      expect(same.metadata.mimeType, 'video/mp4');
      expect(same.metadata.referer, 'https://example/player');
      expect(same.metadata.processName, 'Browser');
      expect(same.metadata.etag, 'v1');
      expect(same.contentRevision, 0);

      store.record(metadata(url, time.add(const Duration(seconds: 1)), requestId: 'fresh'), countHit: true);
      final fresh = store.findByUrl(url)!;
      expect(fresh.metadata.sizeBytes, isNull);
      expect(fresh.metadata.mimeType, isNull);
      expect(fresh.metadata.referer, isNull);
      expect(fresh.metadata.processName, isNull);
      expect(fresh.metadata.etag, isNull);
      expect(fresh.metadata.lastModified, isNull);
      expect(fresh.contentRevision, 1);
    });

    test('304 inherits representation fields but never the previous request context', () {
      final store = ResourceSnifferStore();
      final time = DateTime.utc(2026, 10, 2);
      const url = 'https://cdn.example/video.mp4';
      store.record(
          metadata(url, time,
              size: 100,
              mime: 'video/mp4',
              referer: 'https://example/player',
              processName: 'Browser',
              etag: 'v1',
              lastModified: 'Thu, 01 Oct 2026 00:00:00 GMT'),
          countHit: true);
      store.record(metadata(url, time.add(const Duration(seconds: 1)), requestId: 'cached', status: 304),
          countHit: true);
      final cached = store.findByUrl(url)!;
      expect(cached.metadata.sizeBytes, 100);
      expect(cached.metadata.mimeType, 'video/mp4');
      expect(cached.metadata.referer, isNull);
      expect(cached.metadata.processName, isNull);
      expect(cached.metadata.etag, 'v1');
      expect(cached.metadata.lastModified, 'Thu, 01 Oct 2026 00:00:00 GMT');
      expect(cached.metadata.statusCode, 304);
      expect(cached.contentRevision, 0);
    });

    test('content revisions cover validators and method; equal-clock late finals do not replace latest', () {
      final store = ResourceSnifferStore();
      final time = DateTime.utc(2026, 10, 2);
      const url = 'https://cdn.example/video.mp4';
      store.record(metadata(url, time, requestId: 'old', mime: 'video/mp4', size: 100, etag: 'v1'), countHit: true);
      store.record(metadata(url, time, requestId: 'latest', mime: 'video/mp4', size: 100, etag: 'v2'), countHit: true);
      expect(store.findByUrl(url)!.contentRevision, 1);
      store.record(metadata(url, time, requestId: 'old', mime: 'video/mp4', size: 200, etag: 'old'), countHit: false);
      expect(store.findByUrl(url)!.metadata.requestId, 'latest');
      expect(store.findByUrl(url)!.metadata.sizeBytes, 100);
      expect(store.findByUrl(url)!.contentRevision, 1);
      store.record(
          metadata(url, time, requestId: 'latest', mime: 'video/mp4', size: 100, etag: 'v2', lastModified: 'new-date'),
          countHit: false);
      expect(store.findByUrl(url)!.contentRevision, 2);
      store.record(
          metadata(url, time,
              requestId: 'post', method: 'POST', mime: 'video/mp4', size: 100, etag: 'v2', lastModified: 'new-date'),
          countHit: true);
      expect(store.findByUrl(url)!.contentRevision, 3);
      expect(store.findByUrl(url)!.toJson()['contentRevision'], 3);
    });

    test('full URLs preserve signatures and repeated requests merge metadata', () {
      final store = ResourceSnifferStore();
      final time = DateTime.utc(2026, 10, 2);
      store.record(metadata('https://cdn.example/video.mp4?token=1', time, mime: 'video/mp4'), countHit: true);
      store.record(metadata('https://cdn.example/video.mp4?token=1', time, size: 1234), countHit: false);
      expect(store.matching().single.hitCount, 1);
      expect(store.matching().single.metadata.sizeBytes, 1234);
      expect(store.matching().single.metadata.mimeType, 'video/mp4');
      store.record(
          metadata('https://cdn.example/video.mp4?token=1', time.add(const Duration(seconds: 1)), requestId: 'r2'),
          countHit: true);
      store.record(metadata('https://cdn.example/video.mp4?token=2', time), countHit: true);
      expect(store.length, 2);
      expect(store.matching(keyword: 'token=1').single.hitCount, 2);
    });

    test('evicts least recently seen entry and late finals cannot restore it', () {
      final store = ResourceSnifferStore(maxEntries: 2);
      final time = DateTime.utc(2026, 10, 2);
      const first = 'https://a.example/first.mp4';
      const second = 'https://a.example/second.mp4';
      store.record(metadata(first, time), countHit: true);
      store.record(metadata(second, time.add(const Duration(seconds: 1))), countHit: true);
      store.record(metadata(first, time.add(const Duration(seconds: 2))), countHit: true);
      store.record(metadata('https://b.example/third.mp4', time.add(const Duration(seconds: 3))), countHit: true);
      expect(store.matching().map((entry) => entry.metadata.url), [
        'https://b.example/third.mp4',
        first,
      ]);
      store.record(metadata(second, time.add(const Duration(seconds: 1)), size: 42), countHit: false);
      expect(store.length, 2);
      expect(store.matching(keyword: 'second'), isEmpty);
    });

    test('filters category, host, keywords and ids; clear advances revision', () {
      final store = ResourceSnifferStore();
      final time = DateTime.utc(2026, 10, 2);
      store.record(metadata('https://a.example/movie.mp4', time), countHit: true);
      store.record(metadata('https://b.example/clip.mp4', time.add(const Duration(seconds: 1))), countHit: true);
      expect(store.hosts, ['a.example', 'b.example']);
      expect(store.matching(host: 'A.EXAMPLE', keyword: 'MOVIE', kind: 'video'), hasLength(1));
      expect(store.matching(kind: 'audio'), isEmpty);
      final entry = store.matching().first;
      expect(store.matching(ids: {entry.id}).single.metadata.url, entry.metadata.url);
      final json = entry.toJson();
      expect(json['firstSeen'], time.add(const Duration(seconds: 1)).toIso8601String());
      expect(json['sizeBytes'], isNull);
      final before = store.revision;
      store.clear();
      expect(store.length, 0);
      expect(store.revision, greaterThan(before));
    });
  });
}
