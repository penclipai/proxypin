import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:window_manager/window_manager.dart';

typedef ResourceSnifferCommand = Future<Map<String, dynamic>> Function(String method, Map<String, dynamic> arguments);

/// Opening, filtering and exporting the collection only fetch metadata. Media
/// requests are made through the main window only after an explicit preview.
class ResourceSnifferPage extends StatefulWidget {
  final String? windowId;
  final ResourceSnifferCommand? command;

  const ResourceSnifferPage({super.key, this.windowId, this.command});

  @override
  State<ResourceSnifferPage> createState() => _ResourceSnifferPageState();
}

class _ResourceSnifferPageState extends State<ResourceSnifferPage> with WindowListener {
  static const _pageSize = 100;
  static int _nextPreviewClient = 0;
  late final String _previewClientId;
  final _search = TextEditingController();
  final _selected = <String>{};
  final _verticalScroll = ScrollController(keepScrollOffset: false);
  final _previews = <String, _ResourcePreview>{};
  final _previewChanges = ValueNotifier<int>(0);
  Timer? _poll;
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _resources = [];
  List<String> _hosts = [];
  Map<String, dynamic> _config = {'enabled': true, 'includeImages': false, 'rules': []};
  String _kind = 'all';
  String _host = '';
  String? _error;
  int? _revision;
  int _total = 0;
  int _offset = 0;
  int _filterGeneration = 0;
  bool _querying = false;
  bool _pendingReload = false;
  bool _loaded = false;
  bool _busy = false;
  String? _activePreviewId;
  int _previewGeneration = 0;
  int? _collectionGeneration;
  int _previewBytes = 0;
  Future<void>? _closeProtection;
  bool _closing = false;

  AppLocalizations get l => AppLocalizations.of(context)!;
  bool get _enabled => _config['enabled'] != false;

  @override
  void initState() {
    super.initState();
    _previewClientId =
        '${widget.windowId ?? 'sniffer'}-${DateTime.now().microsecondsSinceEpoch}-${_nextPreviewClient++}';
    unawaited(_query(force: true));
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_busy) unawaited(_query());
    });
    if (widget.windowId != null) {
      HardwareKeyboard.instance.addHandler(_keyEvent);
      // Native X destroys the child engine without disposing its widgets.
      // Intercept only this tool's child window so its IPC can finish first.
      windowManager.addListener(this);
      _closeProtection = windowManager.setPreventClose(true).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _searchDebounce?.cancel();
    unawaited(_cancelActivePreview(notify: false));
    _discardPreviews(notify: false);
    _previewChanges.dispose();
    _search.dispose();
    _verticalScroll.dispose();
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    if (widget.windowId != null) {
      windowManager.removeListener(this);
      if (!_closing) unawaited(windowManager.setPreventClose(false).catchError((_) {}));
    }
    super.dispose();
  }

  bool _keyEvent(KeyEvent event) {
    if (widget.windowId != null &&
        event is KeyDownEvent &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyW) {
      unawaited(_closeWindow());
      return true;
    }
    return false;
  }

  @override
  void onWindowClose() {
    if (widget.windowId != null) unawaited(_closeWindow());
  }

  Future<void> _closeWindow() async {
    if (_closing || widget.windowId == null) return;
    _closing = true;
    _poll?.cancel();
    _searchDebounce?.cancel();
    try {
      await _closeProtection?.timeout(const Duration(seconds: 1));
    } catch (_) {
      // A missing main engine or native callback must not trap the child open.
    }
    final cancellation = _cancelActivePreview(notify: mounted);
    if (mounted) setState(() {});
    await cancellation.timeout(const Duration(seconds: 2), onTimeout: () {});
    try {
      await windowManager.setPreventClose(false).timeout(const Duration(seconds: 1));
      await windowManager.close().timeout(const Duration(seconds: 1));
    } catch (_) {
      await windowManager.destroy().timeout(const Duration(seconds: 1), onTimeout: () {}).catchError((_) {});
    }
  }

  Future<Map<String, dynamic>> _command(String method, Map<String, dynamic> arguments) async {
    if (widget.command != null) return widget.command!(method, arguments);
    final result = await DesktopMultiWindow.invokeMainWindowMethod<dynamic>(method, arguments);
    if (result is! Map) throw StateError('Invalid resource sniffer response');
    return Map<String, dynamic>.from(result);
  }

  Map<String, dynamic> get _filters => {'keyword': _search.text.trim(), 'kind': _kind, 'host': _host};

  Future<void> _query({bool force = false}) async {
    if (!mounted || _closing) return;
    if (_querying) {
      if (force) _pendingReload = true;
      return;
    }
    _querying = true;
    final generation = _filterGeneration;
    try {
      final result = await _command('resourceSnifferQuery', {
        ..._filters,
        'offset': _offset,
        'limit': _pageSize,
        if (!force && _revision != null) 'knownRevision': _revision,
      });
      if (!mounted || _closing || generation != _filterGeneration) return;
      if (result['unchanged'] == true) {
        if (_error != null) setState(() => _error = null);
        return;
      }
      final collectionGeneration = (result['collectionGeneration'] as num?)?.toInt();
      if (_collectionGeneration != null &&
          collectionGeneration != null &&
          collectionGeneration != _collectionGeneration) {
        unawaited(_cancelActivePreview());
        _discardPreviews();
      }
      _collectionGeneration = collectionGeneration ?? _collectionGeneration;
      final resources = (result['resources'] as List? ?? []).map((r) => Map<String, dynamic>.from(r as Map)).toList();
      _synchronizePreviewRevisions(resources);
      setState(() {
        _revision = (result['revision'] as num?)?.toInt();
        _config = Map<String, dynamic>.from(result['config'] as Map? ?? _config);
        _total = (result['total'] as num?)?.toInt() ?? 0;
        if (_total == 0) _selected.clear();
        _resources = resources;
        _hosts = (result['hosts'] as List? ?? []).map((h) => h.toString()).toList();
        _loaded = true;
        _error = null;
      });
      // An open detail dialog also needs the latest resource metadata.
      _previewChanges.value++;
      // Eviction or clearing in another window can remove the current page.
      if (_offset > 0 && _offset >= _total) {
        setState(() => _offset = _total == 0 ? 0 : ((_total - 1) ~/ _pageSize) * _pageSize);
        _filterGeneration++;
        _pendingReload = true;
      }
    } catch (e) {
      if (mounted && generation == _filterGeneration) {
        setState(() => _error = '${l.resourceSnifferConnectionError}: $e');
      }
    } finally {
      _querying = false;
      if (mounted && _pendingReload) {
        _pendingReload = false;
        unawaited(_query(force: true));
      }
    }
  }

  void _filterChanged() {
    _searchDebounce?.cancel();
    setState(() {
      _offset = 0;
      _selected.clear();
      _revision = null;
      _filterGeneration++;
    });
    if (_verticalScroll.hasClients) _verticalScroll.jumpTo(0);
    unawaited(_query(force: true));
  }

  void _page(int offset) {
    setState(() {
      _offset = offset;
      _filterGeneration++;
    });
    if (_verticalScroll.hasClients) _verticalScroll.jumpTo(0);
    unawaited(_query(force: true));
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy || _closing) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled() => _perform(() async {
        final enabled = !_enabled;
        _filterGeneration++;
        final result = await _command('resourceSnifferSetEnabled', {'enabled': enabled});
        if (!mounted) return;
        _applyMutation(result, config: {..._config, 'enabled': enabled});
        await _query(force: true);
      });

  Future<void> _clear() => _perform(() async {
        _filterGeneration++;
        unawaited(_cancelActivePreview());
        _discardPreviews();
        final result = await _command('resourceSnifferClear', {});
        if (!mounted) return;
        _applyMutation(result);
        setState(() {
          _selected.clear();
          _resources = [];
          _total = 0;
          _offset = 0;
        });
        await _query(force: true);
      });

  Future<void> _cancelActivePreview({bool notify = true}) {
    final id = _activePreviewId;
    var cancellation = Future<void>.value();
    _previewGeneration++;
    _activePreviewId = null;
    if (id != null) {
      final previous = _previews[id];
      if (previous != null) previous.loading = false;
      // A child owns only its current request. Closing it does not clear the
      // main window's cached metadata or previews used by another child.
      cancellation = _command('resourceSnifferCancelPreview', {'id': id, 'clientId': _previewClientId})
          .then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    }
    if (notify) _previewChanges.value++;
    return cancellation;
  }

  void _discardPreviews({bool notify = true}) {
    for (final preview in _previews.values) {
      _evictImage(preview.image);
    }
    _previews.clear();
    _previewBytes = 0;
    if (notify) _previewChanges.value++;
  }

  int? _contentRevision(Map<String, dynamic> resource) => (resource['contentRevision'] as num?)?.toInt();

  _ResourcePreview? _localPreview(Map<String, dynamic> resource) {
    final preview = _previews[resource['id'].toString()];
    return preview?.contentRevision == _contentRevision(resource) ? preview : null;
  }

  void _removePreview(String id) {
    final preview = _previews.remove(id);
    _previewBytes -= preview?.image?.length ?? 0;
    _evictImage(preview?.image);
  }

  void _synchronizePreviewRevisions(List<Map<String, dynamic>> resources) {
    for (final resource in resources) {
      final id = resource['id'].toString();
      final preview = _previews[id];
      if (preview == null || preview.contentRevision == _contentRevision(resource)) continue;
      if (_activePreviewId == id) unawaited(_cancelActivePreview(notify: false));
      _removePreview(id);
    }
  }

  void _evictImage(Uint8List? bytes) {
    if (bytes == null) return;
    final image = MemoryImage(bytes);
    unawaited(image.evict());
    unawaited(ResizeImage.resizeIfNeeded(112, null, image).evict());
    unawaited(ResizeImage.resizeIfNeeded(720, null, image).evict());
  }

  bool _canPreview(Map<String, dynamic> resource) =>
      ['video', 'audio', 'hls', 'dash', 'image'].contains(resource['kind']) &&
      (resource['method'] ?? 'GET') == 'GET' &&
      (!['video', 'audio'].contains(resource['kind']) || (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows));

  String _previewUnavailable(Map<String, dynamic> resource) =>
      ['video', 'audio'].contains(resource['kind']) && (kIsWeb || defaultTargetPlatform != TargetPlatform.windows)
          ? l.resourceSnifferPreviewWindowsOnly
          : l.resourceSnifferPreviewUnavailable;

  Map<String, dynamic> _previewMetadata(Map<String, dynamic> resource) {
    final remote =
        resource['preview'] is Map ? Map<String, dynamic>.from(resource['preview'] as Map) : <String, dynamic>{};
    return {...remote, ...?_localPreview(resource)?.metadata};
  }

  Future<void> _preview(Map<String, dynamic> resource) async {
    final id = resource['id'].toString();
    if (!mounted || _closing || !_canPreview(resource) || _activePreviewId != null) return;
    final current = _previews.remove(id) ?? _ResourcePreview();
    final contentRevision = _contentRevision(resource);
    current.contentRevision = contentRevision;
    current.loading = true;
    current.error = null;
    current.diagnostics = {};
    _previews[id] = current;
    _trimPreviews();
    _activePreviewId = id;
    final generation = ++_previewGeneration;
    setState(() {});
    _previewChanges.value++;
    try {
      final result = await _command('resourceSnifferPreview', {'id': id, 'clientId': _previewClientId});
      if (!mounted || generation != _previewGeneration || _activePreviewId != id) return;
      if (result['error'] != null) {
        current.error = _previewError(result['code']?.toString());
        current.diagnostics = _safePreviewDiagnostics(result['diagnostics']);
        return;
      }
      final replyRevision = (result['contentRevision'] as num?)?.toInt() ?? contentRevision;
      final latest = _resources.where((entry) => entry['id'].toString() == id).firstOrNull;
      if (replyRevision != contentRevision || (latest != null && replyRevision != _contentRevision(latest))) {
        unawaited(_cancelActivePreview(notify: false));
        _removePreview(id);
        setState(() {});
        _previewChanges.value++;
        await _query(force: true);
        return;
      }
      if (result['preview'] is! Map) throw const FormatException('Invalid preview response');
      final metadata = Map<String, dynamic>.from(result['preview'] as Map);
      final encoded = metadata.remove('imageBase64');
      Uint8List? bytes;
      if (encoded is String && encoded.isNotEmpty) {
        // Reject an oversized IPC value before decoding it into another buffer.
        if (encoded.length > 16 * 1024 * 1024 * 4 ~/ 3 + 4) throw const FormatException('Preview image is too large');
        bytes = base64Decode(encoded);
        if (bytes.length > 16 * 1024 * 1024) throw const FormatException('Preview image is too large');
      }
      _previewBytes -= current.image?.length ?? 0;
      _evictImage(current.image);
      current.image = bytes;
      current.metadata = metadata;
      _previewBytes += bytes?.length ?? 0;
      // Keep decoded-image work bounded even while browsing many pages.
      _trimPreviews();
    } catch (_) {
      if (mounted && generation == _previewGeneration && _activePreviewId == id) {
        current.error = l.resourceSnifferPreviewFailed;
      }
    } finally {
      if (mounted && generation == _previewGeneration && _activePreviewId == id) {
        _activePreviewId = null;
        current.loading = false;
        setState(() {});
        _previewChanges.value++;
      }
    }
  }

  String _previewError(String? code) => switch (code) {
        'timeout' => l.resourceSnifferPreviewTimeout,
        'byteLimit' => l.resourceSnifferPreviewLimit,
        'network' || 'httpStatus' || 'redirect' || 'encoding' => l.resourceSnifferPreviewNetwork,
        'tls' => l.resourceSnifferPreviewCertificate,
        'decodeFailed' => l.resourceSnifferPreviewDecodeError,
        'invalidMediaHeader' => l.resourceSnifferPreviewInvalidMediaHeader,
        'codecUnavailable' => l.resourceSnifferPreviewCodecUnavailable,
        'protectedMedia' => l.resourceSnifferPreviewProtectedMedia,
        'manifest' => l.resourceSnifferPreviewManifestError,
        'cancelled' => l.resourceSnifferPreviewCancelled,
        'notFound' => l.resourceSnifferPreviewNotFound,
        'busy' => l.resourceSnifferPreviewBusy,
        'range' => l.resourceSnifferPreviewRangeError,
        'unsupportedMethod' || 'unsupported' => l.resourceSnifferPreviewUnavailable,
        _ => l.resourceSnifferPreviewFailed,
      };

  Map<String, dynamic> _safePreviewDiagnostics(dynamic value) {
    if (value is! Map) return {};
    final stage = value['stage'];
    final status = value['httpStatus'];
    final nativeCode = value['nativeHRESULT'];
    return {
      if (const {
        'resourceRequest',
        'resourceRead',
        'manifestParse',
        'imageDecode',
        'mediaDecode',
        'sourceOpen',
        'streamType',
        'firstFrame',
      }.contains(stage))
        'stage': stage,
      if (status is int && status >= 100 && status <= 599) 'httpStatus': status,
      if (nativeCode is String && nativeCode.length == 10 && RegExp(r'^0x[0-9a-fA-F]{8}$').hasMatch(nativeCode))
        'nativeHRESULT': '0x${nativeCode.substring(2).toUpperCase()}',
      if (value['mediaHeader'] == 'unrecognizedMp4') 'mediaHeader': 'unrecognizedMp4',
    };
  }

  String _previewStage(String stage) => switch (stage) {
        'resourceRequest' => l.resourceSnifferPreviewStageRequest,
        'resourceRead' => l.resourceSnifferPreviewStageRead,
        'manifestParse' => l.resourceSnifferPreviewStageManifest,
        'imageDecode' => l.resourceSnifferPreviewStageImage,
        'mediaDecode' => l.resourceSnifferPreviewStageMedia,
        'sourceOpen' => l.resourceSnifferPreviewStageSource,
        'streamType' => l.resourceSnifferPreviewStageStream,
        'firstFrame' => l.resourceSnifferPreviewStageFrame,
        _ => l.resourceSnifferUnknown,
      };

  void _trimPreviews() {
    while (_previews.length > 32 || _previewBytes > 16 * 1024 * 1024) {
      final oldestId = _previews.keys.first;
      final oldest = _previews.remove(oldestId)!;
      _previewBytes -= oldest.image?.length ?? 0;
      _evictImage(oldest.image);
    }
  }

  void _applyMutation(Map<String, dynamic> result, {Map<String, dynamic>? config}) {
    setState(() {
      // A filter change can start another query while a command is awaiting
      // persistence. Reject that query's pre-mutation config as well.
      _filterGeneration++;
      _config = Map<String, dynamic>.from(result['config'] as Map? ?? config ?? _config);
      _revision = (result['revision'] as num?)?.toInt();
      _error = null;
    });
  }

  Future<void> _updateConfig(Map<String, dynamic> config) async {
    // Recognition settings do not own the shared pause state. Another window
    // may have changed it since this child's last poll.
    final current = {'includeImages': config['includeImages'], 'rules': config['rules']};
    setState(() => _busy = true);
    _filterGeneration++;
    try {
      final result = await _command('resourceSnifferUpdateConfig', {'config': current});
      if (!mounted) return;
      _applyMutation(result, config: current);
      await _query(force: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<Map<String, dynamic>>> _exportResources() async {
    final selected = Set<String>.of(_selected);
    final result = await _command('resourceSnifferExport', {
      ..._filters,
      if (selected.isNotEmpty) 'ids': selected.toList(),
    });
    final resources = (result['resources'] as List? ?? []).map((r) => Map<String, dynamic>.from(r as Map)).toList();
    if (mounted && selected.isNotEmpty) {
      final available = resources.map((r) => r['id'].toString()).toSet();
      setState(() => _selected.removeAll(selected.difference(available)));
    }
    return resources;
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
  }

  Future<void> _copyLinks() => _perform(() async {
        final resources = await _exportResources();
        if (resources.isNotEmpty) await _copy(resources.map((r) => r['url']).join('\n'));
      });

  Future<void> _export(String format) => _perform(() async {
        final resources = await _exportResources();
        if (!mounted || resources.isEmpty) return;
        final text = format == 'txt'
            ? '${resources.map((r) => r['url']).join('\n')}\n'
            : const JsonEncoder.withIndent('  ').convert(resources);
        final saved = await FilePicker.saveFile(
          fileName: 'resources.$format',
          type: FileType.custom,
          allowedExtensions: [format],
          bytes: utf8.encode(text),
        );
        if (mounted && saved != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.saveSuccess)));
        }
      });

  Future<void> _settings() => showDialog<void>(
        context: context,
        builder: (_) => _ResourceSnifferSettings(
          config: _config,
          save: _updateConfig,
        ),
      );

  String _size(dynamic bytes) {
    if (bytes is! num) return l.resourceSnifferUnknown;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _time(dynamic value, {bool full = false}) {
    final time = DateTime.tryParse(value?.toString() ?? '');
    if (time == null) return l.resourceSnifferUnknown;
    return DateFormat(full ? 'yyyy-MM-dd HH:mm:ss' : 'MM-dd HH:mm:ss').format(time.toLocal());
  }

  String _duration(dynamic milliseconds) {
    if (milliseconds is! num || !milliseconds.isFinite || milliseconds < 0) return l.resourceSnifferUnknown;
    final seconds = milliseconds ~/ 1000;
    final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return seconds >= 3600 ? '${seconds ~/ 3600}:$minutes:$remainder' : '$minutes:$remainder';
  }

  String _resolution(Map<String, dynamic> metadata) => metadata['width'] is num && metadata['height'] is num
      ? '${metadata['width']} × ${metadata['height']}'
      : l.resourceSnifferUnknown;

  String _bitrate(dynamic bitrate) {
    if (bitrate is! num || !bitrate.isFinite || bitrate <= 0) return l.resourceSnifferUnknown;
    return bitrate >= 1000000
        ? '${(bitrate / 1000000).toStringAsFixed(2)} Mbps'
        : '${(bitrate / 1000).toStringAsFixed(0)} kbps';
  }

  String _frameRate(dynamic frameRate) => frameRate is num && frameRate.isFinite && frameRate > 0
      ? '${frameRate.toStringAsFixed(2)} fps'
      : l.resourceSnifferUnknown;

  Widget _previewPanel(Map<String, dynamic> resource) {
    final id = resource['id'].toString();
    final preview = _localPreview(resource);
    final metadata = _previewMetadata(resource);
    final variants = metadata['variants'] is List ? metadata['variants'] as List : const [];
    final available = _canPreview(resource);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text(l.resourceSnifferPreview, style: Theme.of(context).textTheme.titleSmall)),
          OutlinedButton.icon(
            key: ValueKey('sniffer-preview-detail-$id'),
            onPressed: available && !_closing && _activePreviewId == null ? () => _preview(resource) : null,
            icon: preview?.loading == true
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.image_search_outlined, size: 18),
            label: Text(preview?.loading == true
                ? l.resourceSnifferPreviewLoading
                : preview?.error != null
                    ? l.resourceSnifferRetry
                    : l.resourceSnifferPreview),
          ),
        ]),
        const SizedBox(height: 6),
        Text(available ? l.resourceSnifferPreviewHint : _previewUnavailable(resource),
            style: Theme.of(context).textTheme.bodySmall),
        if (preview?.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
                preview!.error == l.resourceSnifferPreviewFailed
                    ? preview.error!
                    : '${l.resourceSnifferPreviewFailed}: ${preview.error}',
                key: ValueKey('sniffer-preview-error-$id'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (preview != null && preview.diagnostics.isNotEmpty) ...[
          if (preview.diagnostics['mediaHeader'] == 'unrecognizedMp4' &&
              preview.error != l.resourceSnifferPreviewInvalidMediaHeader)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child:
                  Text(l.resourceSnifferPreviewInvalidMediaHeader, key: ValueKey('sniffer-preview-media-header-$id')),
            ),
          if (preview.diagnostics['stage'] is String)
            _detail(l.resourceSnifferPreviewDiagnosticStage, _previewStage(preview.diagnostics['stage'] as String),
                key: ValueKey('sniffer-preview-stage-$id')),
          if (preview.diagnostics['httpStatus'] != null)
            _detail(l.resourceSnifferPreviewDiagnosticHttpStatus, preview.diagnostics['httpStatus'],
                key: ValueKey('sniffer-preview-http-status-$id')),
          if (preview.diagnostics['nativeHRESULT'] != null)
            _detail(l.resourceSnifferPreviewDiagnosticNativeCode, preview.diagnostics['nativeHRESULT'],
                key: ValueKey('sniffer-preview-native-code-$id')),
        ],
        if (preview?.image != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: Image.memory(
                preview!.image!,
                key: ValueKey('sniffer-preview-image-$id'),
                fit: BoxFit.contain,
                cacheWidth: 720,
                gaplessPlayback: true,
                errorBuilder: (_, error, stackTrace) => Text(l.resourceSnifferPreviewUnavailable),
              ),
            ),
          ),
        if (metadata['type'] == 'manifest')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(l.resourceSnifferManifestPreviewHint),
          ),
        if (metadata.isNotEmpty) ...[
          _detail(l.resourceSnifferResolution, _resolution(metadata)),
          _detail(l.resourceSnifferDuration, _duration(metadata['durationMs'])),
          _detail(l.resourceSnifferCodec, metadata['codec']),
          _detail(l.resourceSnifferFrameRate, _frameRate(metadata['frameRate'])),
          _detail(l.resourceSnifferBitrate, _bitrate(metadata['bitrate'])),
          _detail(l.resourceSnifferContainer, metadata['container']),
          if (variants.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(l.resourceSnifferVariants, style: const TextStyle(fontWeight: FontWeight.w500)),
            for (var index = 0; index < variants.length; index++)
              if (variants[index] is Map)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SelectableText(_variantDescription(Map<String, dynamic>.from(variants[index] as Map))),
                ),
          ],
        ],
        const Divider(height: 24),
      ],
    );
  }

  String _variantDescription(Map<String, dynamic> variant) => [
        if (variant['name'] != null) variant['name'].toString(),
        if (variant['width'] is num && variant['height'] is num) _resolution(variant),
        if (variant['bandwidth'] is num || variant['bitrate'] is num)
          _bitrate(variant['bandwidth'] ?? variant['bitrate']),
        if (variant['codec'] != null || variant['codecs'] != null) (variant['codec'] ?? variant['codecs']).toString(),
        if (variant['frameRate'] is num) _frameRate(variant['frameRate']),
        if (variant['uri'] != null || variant['url'] != null) (variant['uri'] ?? variant['url']).toString(),
      ].join(' · ');

  String _matchReason(dynamic value) {
    final reason = value?.toString() ?? '';
    final colon = reason.indexOf(':');
    if (colon < 0) return reason;
    final prefix = reason.substring(0, colon).toLowerCase();
    final pattern = reason.substring(colon + 1);
    if (prefix == 'custom') {
      final typeColon = pattern.indexOf(':');
      if (typeColon < 0) return reason;
      final type = pattern.substring(0, typeColon);
      final label = switch (type) {
        'extension' => l.resourceSnifferExtension,
        'urlRegex' => l.resourceSnifferUrlRegex,
        _ => 'MIME',
      };
      return '${l.resourceSnifferRules} · $label: ${pattern.substring(typeColon + 1)}';
    }
    final label = switch (prefix) {
      'mime' => 'MIME',
      'filename' => l.name,
      'extension' => l.resourceSnifferExtension,
      _ => null,
    };
    return label == null ? reason : '$label: $pattern';
  }

  Future<void> _details(Map<String, dynamic> resource) => showDialog<void>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: _previewChanges,
          builder: (context, _) {
            final current = _resources.where((entry) => entry['id'] == resource['id']).firstOrNull ??
                {...resource, 'preview': null};
            return AlertDialog(
              title: Text(current['fileName']?.toString() ?? l.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              content: SizedBox(
                width: 660,
                height: math.min(620, MediaQuery.sizeOf(context).height * 0.7),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _previewPanel(current),
                      _detail('URL', current['url']),
                      _detail(l.resourceSnifferCategory, _kindLabel(l, current['kind']?.toString() ?? 'other')),
                      _detail(l.statusCode, current['statusCode']),
                      _detail('MIME', current['mimeType']),
                      _detail(l.resourceSnifferSize, _size(current['sizeBytes'])),
                      _detail('Referer', current['referer']),
                      _detail(l.resourceSnifferProcess, current['processName']),
                      _detail(l.resourceSnifferReason, _matchReason(current['matchReason'])),
                      _detail(l.resourceSnifferCount, current['hitCount']),
                      _detail(l.resourceSnifferFirstSeen, _time(current['firstSeen'], full: true)),
                      _detail(l.resourceSnifferLastSeen, _time(current['lastSeen'], full: true)),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => _perform(() => _copy(current['url'].toString())),
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(l.resourceSnifferCopyLinks),
                ),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.close)),
              ],
            );
          },
        ),
      );

  Widget _detail(String label, dynamic value, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 125, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
            const SizedBox(width: 12),
            Expanded(
                child:
                    SelectableText(value?.toString().isNotEmpty == true ? value.toString() : l.resourceSnifferUnknown)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(l.resourceSniffer, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('sniffer-toggle'),
                  onPressed: _busy || !_loaded ? null : _setEnabled,
                  icon: Icon(_enabled ? Icons.pause : Icons.play_arrow, size: 18),
                  label: Text(_enabled ? l.resourceSnifferPause : l.resourceSnifferResume),
                ),
                OutlinedButton.icon(
                  key: const Key('sniffer-clear'),
                  onPressed: _busy || !_loaded ? null : _clear,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(l.clear),
                ),
                OutlinedButton.icon(
                  key: const Key('sniffer-copy'),
                  onPressed: _busy || _total == 0 ? null : _copyLinks,
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(l.resourceSnifferCopyLinks),
                ),
                PopupMenuButton<String>(
                  key: const Key('sniffer-export'),
                  enabled: !_busy && _total > 0,
                  tooltip: l.export,
                  onSelected: _export,
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'txt', child: Text('${l.export} TXT')),
                    PopupMenuItem(value: 'json', child: Text('${l.export} JSON')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.file_upload_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text(l.export),
                    ]),
                  ),
                ),
                IconButton(
                  key: const Key('sniffer-settings'),
                  onPressed: !_loaded || _busy ? null : _settings,
                  tooltip: l.resourceSnifferSettings,
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, constraints) {
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: math.min(330, constraints.maxWidth),
                    child: TextField(
                      key: const Key('sniffer-search'),
                      controller: _search,
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        labelText: l.search,
                        prefixIcon: const Icon(Icons.search, size: 20),
                      ),
                      onChanged: (_) {
                        _searchDebounce?.cancel();
                        _searchDebounce = Timer(const Duration(milliseconds: 250), _filterChanged);
                      },
                      onSubmitted: (_) => _filterChanged(),
                    ),
                  ),
                  SizedBox(
                    width: math.min(160, constraints.maxWidth),
                    child: DropdownButtonFormField<String>(
                      key: const Key('sniffer-kind'),
                      initialValue: _kind,
                      decoration: InputDecoration(
                          isDense: true, border: const OutlineInputBorder(), labelText: l.resourceSnifferCategory),
                      items: ['all', ..._kinds]
                          .map((kind) => DropdownMenuItem(value: kind, child: Text(_kindLabel(l, kind))))
                          .toList(),
                      onChanged: (value) {
                        _kind = value ?? 'all';
                        _filterChanged();
                      },
                    ),
                  ),
                  SizedBox(
                    width: math.min(260, constraints.maxWidth),
                    child: DropdownButtonFormField<String>(
                      key: const Key('sniffer-host'),
                      initialValue: _host,
                      isExpanded: true,
                      decoration:
                          InputDecoration(isDense: true, border: const OutlineInputBorder(), labelText: l.domain),
                      items: {'', ..._hosts, if (_host.isNotEmpty) _host}
                          .map((host) => DropdownMenuItem(
                              value: host, child: Text(host.isEmpty ? l.all : host, overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: (value) {
                        _host = value ?? '';
                        _filterChanged();
                      },
                    ),
                  ),
                ],
              );
            }),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(children: [
                    Expanded(child: Text(_error!, maxLines: 3, overflow: TextOverflow.ellipsis)),
                    TextButton(onPressed: () => _query(force: true), child: Text(l.resourceSnifferRetry)),
                  ]),
                ),
              ),
            ],
            if (!_enabled) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.resourceSnifferPaused)),
            const SizedBox(height: 12),
            Expanded(
              child: !_loaded && _error == null
                  ? const Center(child: CircularProgressIndicator())
                  : _resources.isEmpty
                      ? Center(child: Text(l.resourceSnifferEmpty, textAlign: TextAlign.center))
                      : _table(),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                  TextButton(
                    key: const Key('sniffer-clear-selection'),
                    onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
                    child: Text('${l.resourceSnifferSelected}: ${_selected.length}'),
                  ),
                  Text(' ·  ${l.all}: $_total'),
                ]),
              ),
              IconButton(
                key: const Key('sniffer-previous'),
                onPressed: _offset == 0 ? null : () => _page(math.max(0, _offset - _pageSize)),
                tooltip: l.resourceSnifferPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${_total == 0 ? 0 : _offset + 1}–${math.min(_offset + _pageSize, _total)} / $_total'),
              IconButton(
                key: const Key('sniffer-next'),
                onPressed: _offset + _pageSize >= _total ? null : () => _page(_offset + _pageSize),
                tooltip: l.resourceSnifferNext,
                icon: const Icon(Icons.chevron_right),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _table() => LayoutBuilder(builder: (context, constraints) {
        // Header and rows share the available width, including a clear gutter
        // for the vertical scrollbar. Long values remain available in tooltips
        // and details instead of forcing the window to scroll horizontally.
        const scrollbarGutter = 12.0;
        final flexibleWidth = math.max(0.0, constraints.maxWidth - scrollbarGutter - 40 - 72 - 48 - 48);
        final nameWidth = flexibleWidth * 0.32;
        final kindWidth = flexibleWidth * 0.08;
        final previewWidth = flexibleWidth * 0.11;
        final hostWidth = flexibleWidth * 0.13;
        final mimeWidth = flexibleWidth * 0.13;
        final sizeWidth = flexibleWidth * 0.09;
        const countWidth = 48.0;
        final timeWidth = flexibleWidth * 0.14;
        final allSelected = _resources.every((r) => _selected.contains(r['id'].toString()));
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Column(children: [
            Container(
              key: const Key('sniffer-table-header'),
              height: 42,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.only(right: scrollbarGutter),
              child: Row(children: [
                SizedBox(
                  width: 40,
                  child: Checkbox(
                    key: const Key('sniffer-select-page'),
                    value: allSelected,
                    tristate: true,
                    onChanged: (_) => setState(() {
                      final ids = _resources.map((r) => r['id'].toString());
                      if (allSelected) {
                        _selected.removeAll(ids);
                      } else {
                        _selected.addAll(ids);
                      }
                    }),
                  ),
                ),
                _cell(l.resourceSnifferPreview, 72),
                _cell(l.name, nameWidth),
                _cell(l.resourceSnifferCategory, kindWidth),
                _cell('${l.resourceSnifferResolution} / ${l.resourceSnifferDuration}', previewWidth),
                _cell(l.domain, hostWidth),
                _cell('MIME', mimeWidth),
                _cell(l.resourceSnifferSize, sizeWidth),
                _cell(l.resourceSnifferCount, countWidth),
                _cell(l.resourceSnifferLastSeen, timeWidth),
                const SizedBox(width: 48),
              ]),
            ),
            Expanded(
              child: Scrollbar(
                key: const Key('sniffer-vertical-scrollbar'),
                controller: _verticalScroll,
                thumbVisibility: true,
                trackVisibility: true,
                interactive: true,
                thickness: 10,
                scrollbarOrientation: ScrollbarOrientation.right,
                notificationPredicate: (notification) => notification.metrics.axis == Axis.vertical,
                child: ListView.builder(
                  key: const Key('sniffer-resource-list'),
                  controller: _verticalScroll,
                  padding: const EdgeInsets.only(right: scrollbarGutter),
                  itemExtent: 64,
                  itemCount: _resources.length,
                  findChildIndexCallback: (key) {
                    if (key is! _ResourceRowKey) return null;
                    final index = _resources.indexWhere((resource) => resource['id'].toString() == key.value);
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (_, index) {
                    final resource = _resources[index];
                    final id = resource['id'].toString();
                    return Material(
                      key: _ResourceRowKey(id),
                      color: _selected.contains(id)
                          ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
                          : index.isEven
                              ? Theme.of(context).colorScheme.surface
                              : Theme.of(context).colorScheme.surfaceContainerLowest,
                      child: InkWell(
                        key: ValueKey('sniffer-resource-$id'),
                        onTap: () => _details(resource),
                        child: Row(children: [
                          SizedBox(
                            width: 40,
                            child: Checkbox(
                              key: ValueKey('sniffer-select-$id'),
                              value: _selected.contains(id),
                              onChanged: (checked) =>
                                  setState(() => checked == true ? _selected.add(id) : _selected.remove(id)),
                            ),
                          ),
                          _previewThumbnail(resource),
                          _cell(resource['fileName']?.toString() ?? '', nameWidth),
                          _cell(_kindLabel(l, resource['kind']?.toString() ?? 'other'), kindWidth),
                          _previewSummary(resource, previewWidth),
                          _cell(resource['host']?.toString() ?? '', hostWidth),
                          _cell(resource['mimeType']?.toString() ?? l.resourceSnifferUnknown, mimeWidth),
                          _cell(_size(resource['sizeBytes']), sizeWidth),
                          _cell('${resource['hitCount'] ?? 1}', countWidth),
                          _cell(_time(resource['lastSeen']), timeWidth),
                          SizedBox(
                            width: 48,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton(
                                key: ValueKey('sniffer-copy-$id'),
                                onPressed: () => _perform(() => _copy(resource['url'].toString())),
                                icon: const Icon(Icons.copy, size: 17),
                                tooltip: l.resourceSnifferCopyLinks,
                              ),
                            ),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ),
          ]),
        );
      });

  Widget _previewThumbnail(Map<String, dynamic> resource) {
    final id = resource['id'].toString();
    final preview = _localPreview(resource);
    final available = _canPreview(resource);
    return SizedBox(
      width: 72,
      child: Center(
        child: SizedBox(
          width: 56,
          height: 42,
          child: preview?.image != null
              ? Tooltip(
                  message: preview?.error != null
                      ? '${l.resourceSnifferRetry}: ${preview!.error}'
                      : l.resourceSnifferPreview,
                  child: InkWell(
                    key: ValueKey('sniffer-preview-$id'),
                    onTap: () => _details(resource),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.memory(
                        preview!.image!,
                        key: ValueKey('sniffer-preview-thumbnail-$id'),
                        fit: BoxFit.contain,
                        cacheWidth: 112,
                        errorBuilder: (_, error, stackTrace) => const Icon(Icons.broken_image_outlined, size: 22),
                      ),
                    ),
                  ),
                )
              : IconButton(
                  key: ValueKey('sniffer-preview-$id'),
                  onPressed: available && !_closing && _activePreviewId == null ? () => _preview(resource) : null,
                  tooltip: !available
                      ? _previewUnavailable(resource)
                      : preview?.error != null
                          ? '${l.resourceSnifferRetry}: ${preview!.error}'
                          : l.resourceSnifferPreviewHint,
                  icon: preview?.loading == true
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(
                          preview?.error != null
                              ? Icons.refresh
                              : resource['kind'] == 'audio'
                                  ? Icons.audio_file_outlined
                                  : Icons.image_search_outlined,
                          size: 22,
                        ),
                ),
        ),
      ),
    );
  }

  Widget _previewSummary(Map<String, dynamic> resource, double width) {
    final metadata = _previewMetadata(resource);
    return SizedBox(
      width: width,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: width < 72 ? 4 : 8),
        child: metadata.isEmpty
            ? const Text('—')
            : Tooltip(
                message: '${_resolution(metadata)} · ${_duration(metadata['durationMs'])}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_resolution(metadata),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    Text(_duration(metadata['durationMs']),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _cell(String value, double width) => SizedBox(
        width: width,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: width < 72 ? 4 : 8),
          child: Tooltip(
              message: value,
              child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        ),
      );
}

class _ResourcePreview {
  int? contentRevision;
  bool loading = false;
  String? error;
  Uint8List? image;
  Map<String, dynamic> metadata = {};
  Map<String, dynamic> diagnostics = {};
}

class _ResourceRowKey extends ValueKey<String> {
  const _ResourceRowKey(super.value);
}

const _kinds = ['audio', 'video', 'hls', 'dash', 'image', 'other'];

String _kindLabel(AppLocalizations l, String kind) => switch (kind) {
      'all' => l.all,
      'audio' => l.resourceSnifferAudio,
      'video' => l.resourceSnifferVideo,
      'hls' => 'HLS',
      'dash' => 'DASH',
      'image' => l.resourceSnifferImage,
      _ => l.other,
    };

class _ResourceSnifferSettings extends StatefulWidget {
  final Map<String, dynamic> config;
  final Future<void> Function(Map<String, dynamic>) save;

  const _ResourceSnifferSettings({required this.config, required this.save});

  @override
  State<_ResourceSnifferSettings> createState() => _ResourceSnifferSettingsState();
}

class _RuleDraft {
  final String id;
  final TextEditingController pattern;
  String type;
  String kind;
  bool enabled;

  _RuleDraft(Map<String, dynamic> rule)
      : id = rule['id']?.toString() ?? 'rule-${DateTime.now().microsecondsSinceEpoch}',
        pattern = TextEditingController(text: rule['pattern']?.toString() ?? ''),
        type = rule['type']?.toString() ?? 'extension',
        kind = rule['kind']?.toString() ?? 'video',
        enabled = rule['enabled'] != false;

  Map<String, dynamic> toJson() =>
      {'id': id, 'type': type, 'pattern': pattern.text.trim(), 'kind': kind, 'enabled': enabled};
}

class _ResourceSnifferSettingsState extends State<_ResourceSnifferSettings> {
  late bool _images;
  late List<_RuleDraft> _rules;
  bool _saving = false;
  String? _error;

  AppLocalizations get l => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _images = widget.config['includeImages'] == true;
    _rules =
        (widget.config['rules'] as List? ?? []).map((r) => _RuleDraft(Map<String, dynamic>.from(r as Map))).toList();
  }

  @override
  void dispose() {
    for (final rule in _rules) {
      rule.pattern.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    for (var index = 0; index < _rules.length; index++) {
      final rule = _rules[index];
      try {
        if (rule.pattern.text.trim().isEmpty) throw const FormatException('Empty pattern');
        if (rule.type == 'urlRegex') RegExp(rule.pattern.text.trim());
      } on FormatException catch (e) {
        setState(() => _error = '${l.resourceSnifferInvalidRule} (${index + 1}): ${e.message}');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save({...widget.config, 'includeImages': _images, 'rules': _rules.map((r) => r.toJson()).toList()});
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _move(int from, int to) => setState(() {
        final rule = _rules.removeAt(from);
        _rules.insert(to, rule);
      });

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(l.resourceSnifferSettings),
        content: SizedBox(
          width: 780,
          height: 470,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SwitchListTile(
              key: const Key('sniffer-images'),
              contentPadding: EdgeInsets.zero,
              title: Text(l.resourceSnifferIncludeImages),
              value: _images,
              onChanged: _saving ? null : (value) => setState(() => _images = value),
            ),
            Row(children: [
              Expanded(child: Text(l.resourceSnifferRules, style: const TextStyle(fontWeight: FontWeight.w600))),
              TextButton.icon(
                key: const Key('sniffer-add-rule'),
                onPressed: _saving ? null : () => setState(() => _rules.add(_RuleDraft({}))),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l.add),
              ),
            ]),
            Text(l.resourceSnifferRulesHint, style: Theme.of(context).textTheme.bodySmall),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!,
                    key: const Key('sniffer-rule-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _rules.length,
                itemBuilder: (_, index) => _ruleRow(_rules[index], index),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: Text(l.cancel)),
          FilledButton(key: const Key('sniffer-save-settings'), onPressed: _saving ? null : _save, child: Text(l.save)),
        ],
      );

  Widget _ruleRow(_RuleDraft rule, int index) => Card(
        key: ValueKey(rule),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 32,
                  child: Checkbox(
                    value: rule.enabled,
                    onChanged: _saving ? null : (value) => setState(() => rule.enabled = value == true),
                  ),
                ),
                Text('${index + 1}'),
                SizedBox(
                  width: 200,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('${rule.id}-type-${rule.type}'),
                    initialValue: rule.type,
                    isExpanded: true,
                    decoration: InputDecoration(isDense: true, labelText: l.type),
                    items: [
                      DropdownMenuItem(value: 'extension', child: Text(l.resourceSnifferExtension)),
                      const DropdownMenuItem(value: 'mime', child: Text('MIME')),
                      DropdownMenuItem(value: 'urlRegex', child: Text(l.resourceSnifferUrlRegex)),
                    ],
                    onChanged: _saving ? null : (value) => setState(() => rule.type = value!),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<String>(
                    initialValue: rule.kind,
                    decoration: InputDecoration(isDense: true, labelText: l.resourceSnifferCategory),
                    items:
                        _kinds.map((kind) => DropdownMenuItem(value: kind, child: Text(_kindLabel(l, kind)))).toList(),
                    onChanged: _saving ? null : (value) => setState(() => rule.kind = value!),
                  ),
                ),
                IconButton(
                    onPressed: _saving || index == 0 ? null : () => _move(index, index - 1),
                    tooltip: l.resourceSnifferMoveUp,
                    icon: const Icon(Icons.arrow_upward, size: 18)),
                IconButton(
                    onPressed: _saving || index == _rules.length - 1 ? null : () => _move(index, index + 1),
                    tooltip: l.resourceSnifferMoveDown,
                    icon: const Icon(Icons.arrow_downward, size: 18)),
                IconButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _rules.removeAt(index);
                            // The removed field stays mounted until the next frame.
                            WidgetsBinding.instance.addPostFrameCallback((_) => rule.pattern.dispose());
                          }),
                  tooltip: l.delete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
            TextField(
              key: ValueKey('sniffer-rule-pattern-${rule.id}'),
              controller: rule.pattern,
              enabled: !_saving,
              decoration: InputDecoration(
                isDense: true,
                labelText: l.resourceSnifferPattern,
                hintText: switch (rule.type) { 'mime' => 'video/mp4', 'urlRegex' => r'\.m3u8(?:\?|$)', _ => 'mp4' },
              ),
            ),
          ]),
        ),
      );
}
