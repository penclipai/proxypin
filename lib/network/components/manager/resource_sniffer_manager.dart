import 'dart:collection';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:proxypin/native/resource_preview_decoder.dart';
import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_sniffer.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_preview.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/path.dart';

class _RequestObservation {
  final int generation;
  final bool eligible;
  DateTime? seenAt;
  String? countedUrl;

  _RequestObservation(this.generation, this.eligible);
}

/// The main window owns this observer. Child windows only use its metadata IPC.
class ResourceSnifferManager extends EventListener {
  static final ResourceSnifferManager instance = ResourceSnifferManager();

  final String? configPath;
  final DateTime Function() _clock;
  final ResourceSnifferStore _store;
  final ResourcePreviewService _previews;
  final Map<String, Map<String, String>> _previewHeaders = {};
  final Map<String, Map<String, dynamic>> _previewMetadata = {};
  final Expando<_RequestObservation> _observations = Expando('resourceSniffer');
  final LinkedHashMap<String, _RequestObservation> _requestIds = LinkedHashMap();
  ResourceSnifferConfig _config = ResourceSnifferConfig();
  final ResourceClassifier _classifier = ResourceClassifier();
  Future<void>? _initialization;
  Future<void> _pendingMutation = Future.value();
  ProxyServer? _server;
  int _generation = 0;
  DateTime? _clearedAt;

  ResourceSnifferManager({
    this.configPath,
    DateTime Function()? clock,
    int maxEntries = 2000,
    ResourcePreviewService? previewService,
    ResourceMediaDecoder? mediaDecoder,
    ResourceMediaCanceller? mediaCanceller,
    ResourceImageDecoder? imageDecoder,
  })  : _clock = clock ?? DateTime.now,
        _store = ResourceSnifferStore(maxEntries: maxEntries),
        _previews = previewService ??
            ResourcePreviewService(
              mediaDecoder: mediaDecoder ?? ResourcePreviewDecoder.decode,
              mediaCanceller: mediaCanceller ?? ResourcePreviewDecoder.cancel,
              imageDecoder: imageDecoder ?? ResourcePreviewDecoder.decodeImage,
            );

  ResourceSnifferConfig get config => _config;
  int get revision => _store.revision;
  int get resourceCount => _store.length;

  Future<void> initialize() => _initialization ??= _loadConfig();

  Future<File> _configFile() async {
    if (configPath != null) return File(configPath!);
    final directory = await Paths.homePath();
    return File('$directory${Platform.pathSeparator}resource_sniffer.json');
  }

  Future<void> _loadConfig() async {
    try {
      final file = await _configFile();
      if (!await file.exists()) {
        await _persist(_config);
        return;
      }
      final content = await file.readAsString();
      if (content.trim().isEmpty) return;
      final json = jsonDecode(content);
      if (json is! Map) throw const FormatException('Resource sniffer settings must be an object');
      _config = ResourceSnifferConfig.fromJson(Map<String, dynamic>.from(json));
      _store.configurationChanged();
    } catch (error, stack) {
      // A bad or unavailable settings file must never prevent proxy startup.
      logger.w('Unable to load resource sniffer settings', error: error, stackTrace: stack);
    }
  }

  Future<void> _persist(ResourceSnifferConfig config) async {
    final file = await _configFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(config.toJson()), flush: true);
  }

  void attach(ProxyServer server) {
    if (!identical(_server, server)) {
      _server?.removeListener(this);
      _server = server;
    }
    if (!server.listeners.contains(this)) server.addListener(this);
  }

  @override
  void onRequest(Channel channel, HttpRequest request) {
    try {
      _observation(request, isRequestEvent: true);
    } catch (error, stack) {
      logger.w('Resource sniffer request observation failed', error: error, stackTrace: stack);
    }
  }

  _RequestObservation _observation(HttpRequest request, {bool isRequestEvent = false}) {
    var observation = _observations[request];
    if (observation != null) return observation;
    observation = _requestIds.remove(request.requestId);
    observation ??= _RequestObservation(
      _generation,
      _config.enabled &&
          !_previews.isBridgeUrl(request.requestUrl) &&
          (_clearedAt == null ||
              request.requestTime.isAfter(_clearedAt!) ||
              (isRequestEvent && request.requestTime.isAtSameMomentAs(_clearedAt!))),
    );
    _observations[request] = observation;
    _requestIds[request.requestId] = observation;
    // A bounded scalar ledger covers request copies; weak object associations
    // continue to suppress late finals even after a ledger entry is evicted.
    while (_requestIds.length > _store.maxEntries * 4) {
      _requestIds.remove(_requestIds.keys.first);
    }
    return observation;
  }

  @override
  void onResponseHeaders(ChannelContext channelContext, HttpResponse response) => _observe(channelContext, response);

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) =>
      _observe(channelContext, response, isFinal: true);

  void _observe(ChannelContext context, HttpResponse response, {bool isFinal = false}) {
    try {
      if (!_config.enabled) return;
      final request = response.request ??
          (response.streamId == null ? context.currentRequest : context.getStreamRequest(response.streamId!));
      if (request == null || request.method == HttpMethod.connect) return;
      final observation = _observation(request);
      if (!observation.eligible || observation.generation != _generation) return;
      final status = response.status.code;
      if (!(status >= 200 && status < 300) && status != 304) return;
      final url = request.requestUrl;
      if (_previews.isBridgeUrl(url)) return;
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty || HostFilter.filter(request.hostAndPort?.host ?? uri.host)) return;
      final previous = _store.findByUrl(url);
      final reuseClassification = status == 304 || previous?.metadata.requestId == request.requestId;
      final rawMime = response.headers.get('Content-Type');
      final parsedMime = rawMime?.split(';').first.trim().toLowerCase();
      final mime = parsedMime == null || parsedMime.isEmpty ? null : parsedMime;
      final match = _classifier.classify(
        config: _config,
        url: url,
        mimeType: mime ?? (reuseClassification ? previous?.metadata.mimeType : null),
        contentDisposition: response.headers.get('Content-Disposition'),
        cachedFileName: reuseClassification ? previous?.metadata.fileName : null,
      );
      if (match == null) return;
      // A single request increments once, even if it is observed at headers and final.
      final countHit = observation.countedUrl == null;
      observation.seenAt ??= _clock();
      observation.countedUrl ??= url;
      final evictedId = _store.record(
        ResourceMetadata(
          url: url,
          method: request.method.name.toUpperCase(),
          fileName: match.fileName,
          kind: match.kind,
          mimeType: mime,
          sizeBytes: _size(response, isFinal: isFinal),
          statusCode: status,
          host: uri.host.toLowerCase(),
          referer: request.headers.get('Referer'),
          processName: request.processInfo?.name ?? context.processInfo?.name,
          etag: _validator(response.headers.get('ETag')),
          lastModified: _validator(response.headers.get('Last-Modified')),
          requestId: request.requestId,
          matchReason: match.reason,
          seenAt: observation.seenAt!,
        ),
        countHit: countHit,
      );
      if (evictedId != null) {
        _previewHeaders.remove(evictedId);
        _previewMetadata.remove(evictedId);
        _previews.remove(evictedId);
      }
      final entry = _store.findByUrl(url);
      if (entry != null && previous != null && entry.contentRevision != previous.contentRevision) {
        _previews.remove(entry.id);
        _previewMetadata.remove(entry.id);
      }
      // A late response from an earlier request must not overwrite the latest
      // credentials. Keep a small private header snapshot, never a traffic body.
      if (entry != null && entry.metadata.requestId == request.requestId) {
        _previewHeaders[entry.id] = _requestHeaders(request);
      }
    } catch (error, stack) {
      // Observer failures must not interfere with forwarding or other listeners.
      logger.w('Resource sniffer response observation failed', error: error, stackTrace: stack);
    }
  }

  static String? _validator(String? value) {
    // Validators are only used for bounded content identity, never authentication.
    if (value == null || value.length > 1024) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _size(HttpResponse response, {required bool isFinal}) {
    if (response.status.code == 206) {
      final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)\s*$', caseSensitive: false)
          .firstMatch(response.headers.get('Content-Range')?.trim() ?? '');
      final start = int.tryParse(match?.group(1) ?? '');
      final end = int.tryParse(match?.group(2) ?? '');
      final total = int.tryParse(match?.group(3) ?? '');
      if (start != null && end != null && total != null && start <= end && end < total) return total;
      // Content-Length and body length describe this fragment, not the resource.
      return null;
    }
    final length = int.tryParse(response.headers.get('Content-Length')?.trim() ?? '');
    if (length != null && length >= 0) return length;
    if (isFinal && !response.streamingBody && response.body != null && response.status.code != 304) {
      return response.body!.length;
    }
    return null;
  }

  Future<Map<String, dynamic>> handleCommand(String method, Map<String, dynamic> args) async {
    await initialize();
    if (method == 'resourceSnifferQuery') {
      if (args['knownRevision'] == revision) {
        return {
          'revision': revision,
          'collectionGeneration': _generation,
          'unchanged': true,
          'config': _config.toJson()
        };
      }
      final matches = _matching(args);
      final offset = ((args['offset'] as int?) ?? 0).clamp(0, matches.length);
      final limit = ((args['limit'] as int?) ?? 100).clamp(1, 100);
      return {
        'revision': revision,
        'collectionGeneration': _generation,
        'config': _config.toJson(),
        'total': matches.length,
        'resources': matches.skip(offset).take(limit).map(_toJson).toList(),
        'hosts': _store.hosts,
      };
    }
    if (method == 'resourceSnifferExport') {
      return {'resources': _matching(args).map(_toJson).toList()};
    }
    // Preview must not occupy the mutation queue: cancel and clear have to be
    // able to stop a decoder while its IPC request is still pending.
    if (method == 'resourceSnifferPreview') return _preview(args);
    if (method == 'resourceSnifferCancelPreview') {
      final id = args['id'];
      if (id is! String) throw const FormatException('Resource id must be a string');
      _previews.cancel(id, clientId: _clientId(args));
      return {'cancelled': true};
    }
    final result = _pendingMutation.then((_) => _mutate(method, args));
    _pendingMutation = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Map<String, dynamic> _toJson(SniffedResource entry) => {
        ...entry.toJson(),
        if (_previewMetadata[entry.id] != null) 'preview': _previewMetadata[entry.id],
      };

  Future<Map<String, dynamic>> _preview(Map<String, dynamic> args) async {
    final id = args['id'];
    if (id is! String) throw const FormatException('Resource id must be a string');
    final entry = _store.findById(id);
    if (entry == null) return {'error': 'The resource is no longer available', 'code': 'notFound'};
    final generation = _generation;
    final contentRevision = entry.contentRevision;
    final clientId = _clientId(args);
    try {
      final result = await _previews.preview(
        id: id,
        url: entry.metadata.url,
        kind: entry.metadata.kind,
        headers: _previewHeaders[id] ?? const {},
        method: entry.metadata.method,
        clientId: clientId,
      );
      if (generation != _generation || _store.findById(id)?.contentRevision != contentRevision) {
        return {'error': 'Resource preview was cancelled', 'code': 'cancelled'};
      }
      final metadata = result.toJson();
      if (jsonEncode(metadata) != jsonEncode(_previewMetadata[id])) {
        _previewMetadata[id] = metadata;
        _store.configurationChanged();
      }
      return {
        'preview': result.toJson(includeImage: true),
        'revision': revision,
        'contentRevision': contentRevision,
      };
    } on ResourcePreviewException catch (error) {
      return {
        'error': error.message,
        'code': error.code,
        if (error.diagnostics.isNotEmpty) 'diagnostics': error.diagnostics,
      };
    }
  }

  static String _clientId(Map<String, dynamic> args) {
    final id = args['clientId'] ?? 'legacy';
    if (id is! String || id.isEmpty || id.length > 128) {
      throw const FormatException('Preview client id must be a string');
    }
    return id;
  }

  static Map<String, String> _requestHeaders(HttpRequest request) {
    const allowed = {'referer', 'origin', 'user-agent', 'cookie', 'authorization', 'accept', 'accept-language'};
    final result = <String, String>{};
    var total = 0;
    request.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (!allowed.contains(lower) && !lower.startsWith('x-')) return;
      final value = values.join(lower == 'cookie' ? '; ' : ', ');
      // Capture is bounded even for hostile requests. Normal browser headers
      // fit this allowance; omitted overlong headers simply cannot authenticate.
      if (value.length > 8192 || total + value.length + lower.length > 32768 || result.length >= 64) return;
      result[lower] = value;
      total += value.length + lower.length;
    });
    return result;
  }

  List<SniffedResource> _matching(Map<String, dynamic> args) {
    final rawIds = args['ids'];
    if (rawIds != null && (rawIds is! List || rawIds.any((id) => id is! String))) {
      throw const FormatException('Resource ids must be a list of strings');
    }
    return _store.matching(
      keyword: (args['keyword'] as String?) ?? '',
      kind: (args['kind'] as String?) ?? 'all',
      host: (args['host'] as String?) ?? '',
      ids: rawIds == null ? null : (rawIds as List).cast<String>().toSet(),
    );
  }

  Future<Map<String, dynamic>> _mutate(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'resourceSnifferClear':
        _generation++;
        _clearedAt = _clock();
        _previews.clear();
        _previewHeaders.clear();
        _previewMetadata.clear();
        _store.clear();
        return {'revision': revision};
      case 'resourceSnifferUpdateConfig':
        final json = args['config'];
        if (json is! Map) throw const FormatException('Resource sniffer config must be an object');
        // Pause/resume is an independent command. A stale settings dialog in
        // another window must not replace the current collection state.
        final next = ResourceSnifferConfig.fromJson({...Map<String, dynamic>.from(json), 'enabled': _config.enabled});
        await _persist(next);
        _config = next;
        _store.configurationChanged();
        return {'revision': revision, 'config': _config.toJson()};
      case 'resourceSnifferSetEnabled':
        if (args['enabled'] is! bool) throw const FormatException('enabled must be boolean');
        final next = _config.copyWith(enabled: args['enabled'] as bool);
        await _persist(next);
        _config = next;
        _store.configurationChanged();
        return {'revision': revision, 'config': _config.toJson()};
      default:
        throw FormatException('Unknown resource sniffer command: $method');
    }
  }
}
