import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'resource_sniffer.dart';

typedef ResourceMediaDecoder = Future<Map<String, dynamic>> Function(Uri localUrl);
typedef ResourceImageDecoder = Future<Map<String, dynamic>> Function(Uint8List bytes);
typedef ResourceMediaCanceller = void Function(Uri localUrl);

class ResourcePreviewException implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic> _rawDiagnostics;

  const ResourcePreviewException(this.code, this.message, {Map<String, dynamic> diagnostics = const {}})
      : _rawDiagnostics = diagnostics;

  /// Only bounded enums and numbers may cross IPC. Native messages and URLs
  /// can contain credentials, so neither arbitrary keys nor strings are kept.
  Map<String, dynamic> get diagnostics {
    const stages = {
      'resourceRequest',
      'resourceRead',
      'manifestParse',
      'imageDecode',
      'mediaDecode',
      'sourceOpen',
      'streamType',
      'firstFrame',
    };
    final stage = _rawDiagnostics['stage'];
    final status = _rawDiagnostics['httpStatus'];
    final native = _rawDiagnostics['nativeHRESULT'];
    return {
      if (stage is String && stages.contains(stage)) 'stage': stage,
      if (status is int && status >= 100 && status <= 599) 'httpStatus': status,
      if (native is String && RegExp(r'^0x[0-9a-fA-F]{8}$').hasMatch(native))
        'nativeHRESULT': '0x${native.substring(2).toUpperCase()}',
      if (_rawDiagnostics['mediaHeader'] == 'unrecognizedMp4') 'mediaHeader': 'unrecognizedMp4',
    };
  }

  ResourcePreviewException withDiagnostics(Map<String, dynamic> extra) =>
      ResourcePreviewException(code, message, diagnostics: {...extra, ...diagnostics});

  @override
  String toString() => message;
}

class ResourcePreviewResult {
  final Map<String, dynamic> metadata;
  final Uint8List? imageBytes;

  ResourcePreviewResult(Map<String, dynamic> metadata, this.imageBytes) : metadata = Map.unmodifiable(metadata);

  Map<String, dynamic> toJson({bool includeImage = false}) => {
        ...metadata,
        if (includeImage && imageBytes != null) 'imageBase64': base64Encode(imageBytes!),
      };
}

/// Fetching is deliberately separate from capture. Only an explicit preview
/// command reaches this service, and the OS decoder sees a bounded local bridge.
class ResourcePreviewService {
  final ResourceMediaDecoder mediaDecoder;
  final ResourceMediaCanceller? mediaCanceller;
  final ResourceImageDecoder imageDecoder;
  final Duration timeout;
  final Duration requestTimeout;
  final int maxBytes;
  final int maxImageBytes;
  final int maxManifestBytes;
  final int maxCachedEntries;
  final int maxCachedImageBytes;
  final LinkedHashMap<String, ResourcePreviewResult> _cache = LinkedHashMap();
  final Map<String, _PreviewJob> _pending = {};
  final LinkedHashSet<String> _bridgeUrls = LinkedHashSet();
  int _cachedImageBytes = 0;

  ResourcePreviewService({
    required this.mediaDecoder,
    required this.imageDecoder,
    this.mediaCanceller,
    this.timeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 10),
    this.maxBytes = 16 * 1024 * 1024,
    this.maxImageBytes = 8 * 1024 * 1024,
    this.maxManifestBytes = 1024 * 1024,
    this.maxCachedEntries = 32,
    this.maxCachedImageBytes = 16 * 1024 * 1024,
  }) {
    if (timeout <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxBytes < 1 ||
        maxImageBytes < 1 ||
        maxManifestBytes < 1 ||
        maxCachedEntries < 1 ||
        maxCachedImageBytes < 1) {
      throw ArgumentError('Preview limits must be positive');
    }
  }

  int get pendingCount => _pending.length;
  int get cachedCount => _cache.length;
  int get cachedImageBytes => _cachedImageBytes;

  bool isBridgeUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        _bridgeUrls.contains(Uri(scheme: uri.scheme, host: uri.host, port: uri.port, path: uri.path).toString());
  }

  void _registerBridge(Uri uri) {
    _bridgeUrls.add(uri.toString());
    while (_bridgeUrls.length > 64) {
      _bridgeUrls.remove(_bridgeUrls.first);
    }
  }

  Future<ResourcePreviewResult> preview({
    required String id,
    required String url,
    required ResourceKind kind,
    required Map<String, String> headers,
    String method = 'GET',
    String clientId = 'legacy',
  }) {
    if (method.toUpperCase() != 'GET') {
      return Future.error(
          const ResourcePreviewException('unsupportedMethod', 'Only captured GET resources can be previewed'));
    }
    if (kind == ResourceKind.other) {
      return Future.error(const ResourcePreviewException('unsupported', 'This resource type cannot be previewed'));
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return Future.error(const ResourcePreviewException('unsupported', 'This resource URL cannot be previewed'));
    }
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached;
      return Future.value(cached);
    }
    final pending = _pending[id];
    if (pending != null) {
      pending.owners.add(clientId);
      return pending.future;
    }
    // Serial native decoding also avoids opening an unbounded number of sockets
    // if IPC callers click many rows while previous previews are still loading.
    if (_pending.isNotEmpty) {
      return Future.error(const ResourcePreviewException('busy', 'Another resource preview is already loading'));
    }
    final job = _PreviewJob(this, uri, kind, Map.unmodifiable(headers));
    job.owners.add(clientId);
    _pending[id] = job;
    job.future = _run(id, job);
    return job.future;
  }

  Future<ResourcePreviewResult> _run(String id, _PreviewJob job) async {
    try {
      final result = await job.run();
      job._checkActive();
      _cache[id] = result;
      _cachedImageBytes += result.imageBytes?.length ?? 0;
      while (_cache.length > maxCachedEntries || _cachedImageBytes > maxCachedImageBytes) {
        _removeCached(_cache.keys.first);
      }
      return result;
    } finally {
      if (identical(_pending[id], job)) _pending.remove(id);
    }
  }

  void cancel(String id, {String clientId = 'legacy'}) {
    final job = _pending[id];
    if (job == null) return;
    job.owners.remove(clientId);
    if (job.owners.isEmpty) {
      job.cancel(const ResourcePreviewException('cancelled', 'Resource preview was cancelled'));
    }
  }

  void remove(String id) {
    _pending[id]?.cancel(const ResourcePreviewException('cancelled', 'Resource preview was cancelled'));
    _removeCached(id);
  }

  void _removeCached(String id) {
    final result = _cache.remove(id);
    _cachedImageBytes -= result?.imageBytes?.length ?? 0;
  }

  void clear() {
    for (final job in _pending.values.toList()) {
      job.cancel(const ResourcePreviewException('cancelled', 'Resource preview was cancelled'));
    }
    _cache.clear();
    _cachedImageBytes = 0;
  }
}

class _Fetched {
  final HttpClientResponse response;
  final Uri url;

  _Fetched(this.response, this.url);
}

class _PreviewJob {
  final ResourcePreviewService service;
  final Uri url;
  final ResourceKind kind;
  final Map<String, String> headers;
  final Set<String> owners = {};
  final HttpClient client = HttpClient();
  final Completer<ResourcePreviewException> _cancellation = Completer();
  late Future<ResourcePreviewResult> future;
  HttpServer? _bridge;
  Uri? _mediaUrl;
  Timer? _timer;
  int _transferred = 0;
  ResourcePreviewException? _failure;
  bool _completed = false;
  int? _upstreamStatus;
  String? _mediaMime;
  int? _mediaSize;
  final Uint8List _mediaPrefix = Uint8List(32);
  int _mediaPrefixLength = 0;

  _PreviewJob(this.service, this.url, this.kind, this.headers) {
    client.findProxy = (_) => 'DIRECT';
    client.autoUncompress = false;
    client.connectionTimeout = service.requestTimeout;
  }

  void cancel(ResourcePreviewException failure) {
    if (_failure != null) return;
    _failure = failure;
    _cancellation.complete(failure);
    client.close(force: true);
    unawaited(_bridge?.close(force: true));
    final mediaUrl = _mediaUrl;
    if (mediaUrl != null) {
      try {
        service.mediaCanceller?.call(mediaUrl);
      } catch (_) {
        // Network cancellation must complete even if a platform player fails
        // while tearing down its session.
      }
    }
  }

  void _checkActive() {
    if (_failure != null) throw _failure!;
  }

  Future<ResourcePreviewResult> run() async {
    _timer = Timer(
        service.timeout,
        () => cancel(
              ResourcePreviewException('timeout', 'Resource preview exceeded its time limit',
                  diagnostics: _diagnostics('resourceRead')),
            ));
    try {
      final result = await Future.any([
        _load(),
        _cancellation.future.then<ResourcePreviewResult>((failure) => throw failure),
      ]);
      _checkActive();
      _completed = true;
      return result;
    } on ResourcePreviewException {
      rethrow;
    } on TimeoutException {
      throw ResourcePreviewException('timeout', 'Resource preview exceeded its time limit',
          diagnostics: _diagnostics('resourceRead'));
    } on HandshakeException {
      throw ResourcePreviewException('tls', 'The resource certificate could not be verified',
          diagnostics: _diagnostics('resourceRequest'));
    } on HttpException {
      throw ResourcePreviewException('network', 'The resource could not be read',
          diagnostics: _diagnostics('resourceRead'));
    } on SocketException {
      throw ResourcePreviewException('network', 'The resource could not be reached',
          diagnostics: _diagnostics('resourceRequest'));
    } catch (_) {
      // Decoder and server errors may contain a signed URL. Keep IPC errors
      // useful without disclosing credentials or native diagnostic strings.
      throw ResourcePreviewException('decodeFailed', 'This resource could not be decoded',
          diagnostics: _diagnostics('mediaDecode'));
    } finally {
      _timer?.cancel();
      client.close(force: true);
      await _bridge?.close(force: true);
    }
  }

  Future<ResourcePreviewResult> _load() async {
    if (kind == ResourceKind.hls || kind == ResourceKind.dash) {
      final fetched = await _fetch(url);
      final bytes = await _read(fetched.response, min(service.maxBytes, service.maxManifestBytes));
      late Map<String, dynamic> metadata;
      try {
        final text = utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
        metadata = kind == ResourceKind.hls ? _hls(text, fetched.url) : _dash(text);
      } on ResourcePreviewException catch (error) {
        throw error.withDiagnostics(_diagnostics('manifestParse'));
      } on FormatException {
        throw ResourcePreviewException('manifest', 'The media manifest could not be parsed',
            diagnostics: _diagnostics('manifestParse'));
      } on XmlException {
        throw ResourcePreviewException('manifest', 'The media manifest could not be parsed',
            diagnostics: _diagnostics('manifestParse'));
      }
      _checkActive();
      return ResourcePreviewResult(metadata, null);
    }
    if (kind == ResourceKind.image) {
      final fetched = await _fetch(url);
      final bytes = await _read(fetched.response, min(service.maxBytes, service.maxImageBytes));
      late Map<String, dynamic> decoded;
      try {
        decoded = await service.imageDecoder(bytes);
      } on ResourcePreviewException catch (error) {
        _checkActive();
        throw error.withDiagnostics(_diagnostics('imageDecode'));
      } catch (_) {
        _checkActive();
        throw ResourcePreviewException('decodeFailed', 'This image could not be decoded',
            diagnostics: _diagnostics('imageDecode'));
      }
      _checkActive();
      return _result(decoded, type: 'image');
    }
    final bridge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Cancellation can finish run() while bind is still pending, before its
    // finally block can see this server. The late continuation must close it.
    if (_failure != null) {
      await bridge.close(force: true);
      throw _failure!;
    }
    _bridge = bridge;
    final token = List.generate(24, (_) => Random.secure().nextInt(256));
    final path = '/resource/${base64Url.encode(token).replaceAll('=', '')}';
    _bridge!.listen((request) => unawaited(_serve(request, path)));
    final local = Uri(scheme: 'http', host: '127.0.0.1', port: _bridge!.port, path: path);
    _mediaUrl = local;
    service._registerBridge(local);
    late Map<String, dynamic> decoded;
    try {
      decoded = await service.mediaDecoder(local);
    } on ResourcePreviewException catch (error) {
      _checkActive();
      throw _mediaDecodeFailure(error);
    } catch (_) {
      _checkActive();
      throw _mediaDecodeFailure(const ResourcePreviewException('decodeFailed', 'This resource could not be decoded'));
    }
    _checkActive();
    return _result(decoded, type: kind.name);
  }

  Map<String, dynamic> _diagnostics(String stage) => {
        'stage': stage,
        if (_upstreamStatus != null) 'httpStatus': _upstreamStatus,
      };

  void _failBridge(ResourcePreviewException error) {
    // A decoder can return its first frame while earlier byte ranges are
    // still streaming. Closing those sockets during successful cleanup must
    // not turn the result into a network failure. Explicit user cancellation
    // still calls cancel directly and remains effective until cache commit.
    if (_completed && _failure == null && ['network', 'timeout'].contains(error.code)) {
      return;
    }
    cancel(error);
  }

  ResourcePreviewException _mediaDecodeFailure(ResourcePreviewException error) {
    final diagnostics = {..._diagnostics('mediaDecode'), ...error.diagnostics};
    if (error.code == 'decodeFailed' && _hasUnrecognizedMp4Header()) {
      return ResourcePreviewException(
          'invalidMediaHeader', 'The resource is marked as MP4, but its media header could not be recognized',
          diagnostics: {...diagnostics, 'mediaHeader': 'unrecognizedMp4'});
    }
    return error.withDiagnostics(diagnostics);
  }

  void _rememberPrefix(HttpClientResponse response, String range, List<int> chunk, int offset) {
    if (offset >= 32) return;
    final startsAtZero = response.statusCode == 200 || range.startsWith('bytes=0-');
    if (!startsAtZero) return;
    _mediaMime ??= response.headers.value(HttpHeaders.contentTypeHeader)?.split(';').first.trim().toLowerCase();
    final declaredTotal =
        RegExp(r'^bytes\s+\d+-\d+/(\d+)\s*$').firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    _mediaSize ??= int.tryParse(declaredTotal?[1] ?? '') ??
        (response.statusCode == 200 && response.contentLength >= 0 ? response.contentLength : null);
    final count = min(32 - offset, chunk.length);
    _mediaPrefix.setRange(offset, offset + count, chunk);
    _mediaPrefixLength = max(_mediaPrefixLength, offset + count);
  }

  bool _hasUnrecognizedMp4Header() {
    if (!{'video/mp4', 'audio/mp4', 'application/mp4'}.contains(_mediaMime) || _mediaPrefixLength < 8) return false;
    final bytes = _mediaPrefix;
    // A wrong MIME label on another recognized format is not evidence of an
    // obfuscated MP4. Keep its decoder error rather than assuming protection.
    final signature = latin1.decode(bytes.sublist(0, 4));
    if (signature.startsWith('FLV') ||
        signature == 'RIFF' ||
        signature == 'OggS' ||
        signature.startsWith('ID3') ||
        signature.startsWith('GIF') ||
        signature == 'fLaC' ||
        (bytes[0] == 0x1a && bytes[1] == 0x45 && bytes[2] == 0xdf && bytes[3] == 0xa3) ||
        (bytes[0] == 0x89 && signature.substring(1) == 'PNG') ||
        (bytes[0] == 0xff && (bytes[1] == 0xd8 || bytes[1] & 0xe0 == 0xe0)) ||
        bytes[0] == 0x47) {
      return false;
    }
    const knownBoxes = {
      'ftyp',
      'styp',
      'moov',
      'mdat',
      'free',
      'skip',
      'wide',
      'uuid',
      'sidx',
      'moof',
      'mfra',
      'meta',
      'pdin',
      'prft',
      'emsg',
      'udta',
      'junk',
      'pnot',
      'pict'
    };
    final box = latin1.decode(bytes.sublist(4, 8));
    if (!knownBoxes.contains(box)) return true;
    final data = ByteData.sublistView(bytes);
    final size = data.getUint32(0);
    if (size == 0) return false;
    if (size == 1) {
      if (_mediaPrefixLength < 16) return false;
      final extended = data.getUint64(8);
      return extended < 16 || (_mediaSize != null && extended > _mediaSize!);
    }
    return size < 8 || (_mediaSize != null && size > _mediaSize!);
  }

  ResourcePreviewResult _result(Map<String, dynamic> decoded, {required String type}) {
    final rawImage = decoded['imageBytes'];
    final image = rawImage is Uint8List ? rawImage : (rawImage is List<int> ? Uint8List.fromList(rawImage) : null);
    if (image != null && image.length > service.maxCachedImageBytes) {
      throw const ResourcePreviewException('byteLimit', 'The preview image exceeds its size limit');
    }
    final metadata = <String, dynamic>{
      'type': type,
      'container': _container(url),
      'thumbnailAvailable': image != null,
    };
    for (final key in ['width', 'height', 'durationMs', 'frameRate', 'bitrate']) {
      final value = decoded[key];
      if (value is num && value.isFinite && value >= 0) metadata[key] = value;
    }
    final codec = decoded['codec'];
    if (codec is String && codec.length <= 256) metadata['codec'] = codec;
    return ResourcePreviewResult(metadata, image);
  }

  Future<_Fetched> _fetch(Uri initial, {String method = 'GET', String? range}) async {
    try {
      return await _fetchResource(initial, method: method, range: range);
    } on ResourcePreviewException catch (error) {
      throw error.withDiagnostics(_diagnostics('resourceRequest'));
    } on TimeoutException {
      throw ResourcePreviewException('timeout', 'Resource preview exceeded its time limit',
          diagnostics: _diagnostics('resourceRequest'));
    } on HandshakeException {
      throw ResourcePreviewException('tls', 'The resource certificate could not be verified',
          diagnostics: _diagnostics('resourceRequest'));
    } catch (_) {
      _checkActive();
      throw ResourcePreviewException('network', 'The resource could not be reached',
          diagnostics: _diagnostics('resourceRequest'));
    }
  }

  Future<_Fetched> _fetchResource(Uri initial, {String method = 'GET', String? range}) async {
    var current = initial;
    var forwarded = Map<String, String>.from(headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      _checkActive();
      _upstreamStatus = null;
      final request = await client.openUrl(method, current).timeout(service.requestTimeout);
      request.followRedirects = false;
      forwarded.forEach((name, value) => request.headers.set(name, value));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(service.requestTimeout);
      _upstreamStatus = response.statusCode;
      _checkActive();
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        // No redirect body is needed. Destroy this stream instead of draining
        // an arbitrary body outside the preview byte budget.
        await response.listen((_) {}).cancel();
        if (location == null || redirects == 5) {
          throw const ResourcePreviewException('redirect', 'The resource redirect could not be followed');
        }
        final next = current.resolve(location);
        if (!['http', 'https'].contains(next.scheme) || next.host.isEmpty || next.userInfo.isNotEmpty) {
          throw const ResourcePreviewException('redirect', 'The resource redirect could not be followed');
        }
        if (!_sameOrigin(current, next)) {
          forwarded.removeWhere((name, _) =>
              ['authorization', 'cookie', 'proxy-authorization'].contains(name.toLowerCase()) ||
              name.toLowerCase().startsWith('x-'));
        }
        current = next;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.listen((_) {}).cancel();
        throw ResourcePreviewException('httpStatus', 'The resource returned an unsuccessful HTTP status',
            diagnostics: _diagnostics('resourceRequest'));
      }
      final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        await response.listen((_) {}).cancel();
        throw const ResourcePreviewException('encoding', 'The resource did not provide uncompressed preview bytes');
      }
      return _Fetched(response, current);
    }
    throw const ResourcePreviewException('redirect', 'The resource redirect could not be followed');
  }

  Future<Uint8List> _read(HttpClientResponse response, int limit) async {
    try {
      return await _readBody(response, limit);
    } on ResourcePreviewException catch (error) {
      throw error.withDiagnostics({'stage': 'resourceRead', 'httpStatus': response.statusCode});
    } on TimeoutException {
      throw ResourcePreviewException('timeout', 'Resource preview exceeded its time limit',
          diagnostics: {'stage': 'resourceRead', 'httpStatus': response.statusCode});
    } catch (_) {
      _checkActive();
      throw ResourcePreviewException('network', 'The resource could not be read',
          diagnostics: {'stage': 'resourceRead', 'httpStatus': response.statusCode});
    }
  }

  Future<Uint8List> _readBody(HttpClientResponse response, int limit) async {
    if (response.contentLength > limit) {
      await response.listen((_) {}).cancel();
      throw const ResourcePreviewException('byteLimit', 'The resource exceeds its preview size limit');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(service.requestTimeout)) {
      _checkActive();
      if (bytes.length + chunk.length > limit || _transferred + chunk.length > service.maxBytes) {
        throw const ResourcePreviewException('byteLimit', 'The resource exceeds its preview size limit');
      }
      _transferred += chunk.length;
      bytes.add(chunk);
    }
    _checkActive();
    return bytes.takeBytes();
  }

  Future<void> _serve(HttpRequest request, String path) async {
    var upstreamReceived = false;
    try {
      _checkActive();
      if (request.uri.path != path || !['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final remaining = service.maxBytes - _transferred;
      if (remaining <= 0) {
        throw const ResourcePreviewException('byteLimit', 'The resource exceeds its preview size limit');
      }
      final range = _boundedRange(request.headers.value(HttpHeaders.rangeHeader), min(remaining, 4 * 1024 * 1024));
      late _Fetched fetched;
      var headFallback = false;
      try {
        fetched = await _fetch(url, method: request.method, range: request.method == 'HEAD' ? null : range);
      } on ResourcePreviewException catch (error) {
        if (request.method != 'HEAD' ||
            error.code != 'httpStatus' ||
            ![400, 401, 403, 404, 405, 501].contains(error.diagnostics['httpStatus'])) {
          rethrow;
        }
        // Some GET-signed URLs and media routes reject HEAD. One bounded GET
        // can supply HEAD metadata without reading or forwarding its body.
        fetched = await _fetch(url, range: 'bytes=0-0');
        headFallback = true;
      }
      final response = fetched.response;
      upstreamReceived = true;
      if (request.method != 'HEAD' && response.contentLength > remaining) {
        await response.listen((_) {}).cancel();
        throw const ResourcePreviewException('byteLimit', 'The server did not provide a bounded preview range');
      }
      if (response.statusCode == 206 && !_validRange(response, headFallback ? 'bytes=0-0' : range)) {
        await response.listen((_) {}).cancel();
        throw ResourcePreviewException('range', 'The resource returned an invalid byte range',
            diagnostics: {'stage': 'resourceRead', 'httpStatus': response.statusCode});
      }
      request.response.statusCode = headFallback ? 200 : response.statusCode;
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader
      ]) {
        if (headFallback && name == HttpHeaders.contentRangeHeader) continue;
        final value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      final fullSize = headFallback && response.statusCode == 206
          ? int.tryParse(RegExp(r'^bytes\s+\d+-\d+/(\d+)\s*$')
                  .firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '')?[1] ??
              '')
          : response.contentLength;
      if (fullSize != null && fullSize >= 0) request.response.contentLength = fullSize;
      if (request.method == 'HEAD') {
        await response.listen((_) {}).cancel();
      } else {
        var offset = 0;
        await for (final chunk in response.timeout(service.requestTimeout)) {
          _checkActive();
          if (_transferred + chunk.length > service.maxBytes) {
            throw const ResourcePreviewException('byteLimit', 'The resource exceeds its preview size limit');
          }
          _transferred += chunk.length;
          _rememberPrefix(response, range, chunk, offset);
          offset += chunk.length;
          try {
            request.response.add(chunk);
            await request.response.flush();
          } catch (_) {
            // Native seeking closes an earlier response. Only a downstream
            // write failure is ignored; upstream read failures remain errors.
            return;
          }
        }
      }
      try {
        await request.response.close();
      } catch (_) {}
    } on ResourcePreviewException catch (error) {
      _failBridge(error.withDiagnostics(_diagnostics(upstreamReceived ? 'resourceRead' : 'resourceRequest')));
    } on TimeoutException {
      _failBridge(ResourcePreviewException('timeout', 'Resource preview exceeded its time limit',
          diagnostics: _diagnostics(upstreamReceived ? 'resourceRead' : 'resourceRequest')));
    } on HandshakeException {
      _failBridge(ResourcePreviewException('tls', 'The resource certificate could not be verified',
          diagnostics: _diagnostics('resourceRequest')));
    } catch (_) {
      _failBridge(ResourcePreviewException('network', 'The resource could not be read',
          diagnostics: _diagnostics(upstreamReceived ? 'resourceRead' : 'resourceRequest')));
    }
  }

  static bool _validRange(HttpClientResponse response, String requestedRange) {
    final actual = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$')
        .firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    if (actual == null) return false;
    final start = int.tryParse(actual[1]!);
    final end = int.tryParse(actual[2]!);
    final total = int.tryParse(actual[3]!);
    if (start == null || end == null || start > end || (total != null && end >= total)) return false;
    if (response.contentLength >= 0 && response.contentLength != end - start + 1) return false;
    final requested = RegExp(r'^bytes=(\d*)-(\d+)$').firstMatch(requestedRange)!;
    final limit = int.parse(requested[2]!);
    if (requested[1]!.isEmpty) {
      return total != null && start == max(0, total - limit) && end == total - 1;
    }
    return start == int.parse(requested[1]!) && end <= limit;
  }

  static String _boundedRange(String? raw, int limit) {
    if (raw == null) return 'bytes=0-${limit - 1}';
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(raw.trim());
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      throw const ResourcePreviewException('range', 'Only a single byte range can be previewed');
    }
    if (match[1]!.isEmpty) {
      final suffix = int.tryParse(match[2]!);
      if (suffix == null || suffix <= 0) {
        throw const ResourcePreviewException('range', 'The resource requested an invalid byte range');
      }
      return 'bytes=-${min(suffix, limit)}';
    }
    final start = int.tryParse(match[1]!);
    final end = match[2]!.isEmpty ? null : int.tryParse(match[2]!);
    if (start == null || start < 0 || (match[2]!.isNotEmpty && (end == null || end < start))) {
      throw const ResourcePreviewException('range', 'The resource requested an invalid byte range');
    }
    return 'bytes=$start-${min(end ?? start + limit - 1, start + limit - 1)}';
  }

  static bool _sameOrigin(Uri a, Uri b) => a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  static String? _container(Uri url) {
    final name = url.path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? null : name.substring(dot + 1).toUpperCase();
  }

  static Map<String, dynamic> _hls(String text, Uri base) {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || lines.first.trim() != '#EXTM3U') {
      throw const ResourcePreviewException('manifest', 'The HLS manifest could not be parsed');
    }
    final variants = <Map<String, dynamic>>[];
    Map<String, String>? pending;
    var duration = 0.0;
    var encrypted = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pending = _hlsAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
      } else if (line.isNotEmpty && !line.startsWith('#') && pending != null) {
        if (variants.length < 64) {
          final resolution = RegExp(r'^(\d+)[xX](\d+)$').firstMatch(pending['RESOLUTION'] ?? '');
          variants.add({
            'url': base.resolve(line).toString(),
            if (resolution != null) 'width': int.parse(resolution[1]!),
            if (resolution != null) 'height': int.parse(resolution[2]!),
            if (pending['CODECS'] != null) 'codec': pending['CODECS'],
            if (int.tryParse(pending['BANDWIDTH'] ?? '') case final int value) 'bitrate': value,
            if (_positiveFinite(pending['FRAME-RATE']) case final double value) 'frameRate': value,
          });
        }
        pending = null;
      } else if (line.startsWith('#EXTINF:')) {
        duration += double.tryParse(line.substring(8).split(',').first) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        encrypted |= _hlsAttributes(line.substring(11))['METHOD'] != 'NONE';
      }
    }
    final live = !lines.any((line) => line.trim() == '#EXT-X-ENDLIST');
    return {
      'type': 'manifest',
      'container': 'HLS',
      'thumbnailAvailable': false,
      'variants': variants,
      if (variants.isEmpty) 'live': live,
      'encrypted': encrypted,
      if (!live && duration.isFinite && duration >= 0) 'durationMs': (duration * 1000).round(),
      ..._variantSummary(variants),
    };
  }

  static Map<String, String> _hlsAttributes(String value) => {
        for (final match in RegExp(r'([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))').allMatches(value))
          match[1]!: match[2] ?? match[3] ?? '',
      };

  static Map<String, dynamic> _dash(String text) {
    final document = XmlDocument.parse(text);
    final root = document.rootElement;
    if (root.name.local != 'MPD') {
      throw const ResourcePreviewException('manifest', 'The DASH manifest could not be parsed');
    }
    final variants = <Map<String, dynamic>>[];
    for (final representation
        in root.descendants.whereType<XmlElement>().where((e) => e.name.local == 'Representation')) {
      if (variants.length == 64) break;
      final adaptation = representation.parentElement;
      String? value(String name) => representation.getAttribute(name) ?? adaptation?.getAttribute(name);
      final frameRate = value('frameRate')?.split('/');
      final numerator = frameRate == null ? null : _positiveFinite(frameRate.first);
      final denominator = frameRate == null || frameRate.length == 1 ? 1 : _positiveFinite(frameRate.last);
      variants.add({
        if (value('id') != null) 'id': value('id'),
        if (int.tryParse(value('width') ?? '') case final int width) 'width': width,
        if (int.tryParse(value('height') ?? '') case final int height) 'height': height,
        if (int.tryParse(value('bandwidth') ?? '') case final int bitrate) 'bitrate': bitrate,
        if (value('codecs') != null) 'codec': value('codecs'),
        if (value('mimeType') != null) 'mimeType': value('mimeType'),
        if (numerator != null && denominator != null && (numerator / denominator).isFinite)
          'frameRate': numerator / denominator,
      });
    }
    final duration = _isoDuration(root.getAttribute('mediaPresentationDuration'));
    return {
      'type': 'manifest',
      'container': 'DASH',
      'thumbnailAvailable': false,
      'variants': variants,
      'live': root.getAttribute('type') == 'dynamic',
      'encrypted': root.descendants.whereType<XmlElement>().any((e) => e.name.local == 'ContentProtection'),
      if (duration != null) 'durationMs': duration,
      ..._variantSummary(variants),
    };
  }

  static double? _positiveFinite(String? text) {
    final value = double.tryParse(text ?? '');
    return value != null && value.isFinite && value > 0 ? value : null;
  }

  static int? _isoDuration(String? text) {
    if (text == null) return null;
    final match = RegExp(r'^P(?:(\d+(?:\.\d+)?)D)?T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$')
        .firstMatch(text);
    if (match == null) return null;
    final seconds = (double.tryParse(match[1] ?? '') ?? 0) * 86400 +
        (double.tryParse(match[2] ?? '') ?? 0) * 3600 +
        (double.tryParse(match[3] ?? '') ?? 0) * 60 +
        (double.tryParse(match[4] ?? '') ?? 0);
    return (seconds * 1000).round();
  }

  static Map<String, dynamic> _variantSummary(List<Map<String, dynamic>> variants) {
    if (variants.isEmpty) return {};
    final resolutions = variants.where((v) => v['width'] is int && v['height'] is int).toList()
      ..sort(
          (a, b) => ((b['width'] as int) * (b['height'] as int)).compareTo((a['width'] as int) * (a['height'] as int)));
    final bitrates = variants.map((v) => v['bitrate']).whereType<int>().toList();
    final codecs = variants.map((v) => v['codec']).whereType<String>().toSet();
    return {
      if (resolutions.isNotEmpty) 'width': resolutions.first['width'],
      if (resolutions.isNotEmpty) 'height': resolutions.first['height'],
      if (resolutions.isNotEmpty && resolutions.first['frameRate'] is num) 'frameRate': resolutions.first['frameRate'],
      if (bitrates.isNotEmpty) 'bitrate': bitrates.reduce(max),
      if (codecs.isNotEmpty) 'codec': codecs.join(', '),
    };
  }
}
