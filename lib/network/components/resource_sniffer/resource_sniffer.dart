import 'dart:collection';

enum ResourceKind { audio, video, hls, dash, image, other }

enum ResourceRuleType { extension, mime, urlRegex }

class ResourceSnifferRule {
  final String id;
  final ResourceRuleType type;
  final String pattern;
  final ResourceKind kind;
  final bool enabled;
  final RegExp? _expression;

  ResourceSnifferRule({
    required this.id,
    required this.type,
    required this.pattern,
    required this.kind,
    this.enabled = true,
  }) : _expression = _compile(type, pattern) {
    if (id.trim().isEmpty) throw const FormatException('Rule id must not be empty');
    if (pattern.trim().isEmpty) throw const FormatException('Rule pattern must not be empty');
    if (type == ResourceRuleType.extension &&
        (_extensions(pattern).isEmpty || _extensions(pattern).any((part) => !RegExp(r'^[a-z0-9]+$').hasMatch(part)))) {
      throw const FormatException('Extension rules accept extensions separated by commas, such as mp4,webm');
    }
  }

  static RegExp? _compile(ResourceRuleType type, String pattern) {
    try {
      if (type == ResourceRuleType.urlRegex) return RegExp(pattern);
      if (type == ResourceRuleType.mime) {
        final source = pattern.trim().toLowerCase().split('*').map(RegExp.escape).join('.*');
        return RegExp('^$source\$');
      }
    } on FormatException catch (error) {
      throw FormatException('Invalid URL regular expression: ${error.message}');
    }
    return null;
  }

  static List<String> _extensions(String pattern) => pattern
      .toLowerCase()
      .split(RegExp(r'[,;\s]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part.startsWith('.') ? part.substring(1) : part)
      .toList();

  bool matches(String url, String mimeType, Iterable<String> extensions) {
    if (!enabled) return false;
    return switch (type) {
      ResourceRuleType.extension => extensions.any(_extensions(pattern).contains),
      ResourceRuleType.mime => mimeType.isNotEmpty && _expression!.hasMatch(mimeType),
      ResourceRuleType.urlRegex => _expression!.hasMatch(url),
    };
  }

  factory ResourceSnifferRule.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final pattern = json['pattern'];
    final enabled = json['enabled'] ?? true;
    if (id is! String || pattern is! String || enabled is! bool) {
      throw const FormatException('Every rule needs string id/pattern and a boolean enabled value');
    }
    final type = ResourceRuleType.values.where((value) => value.name == json['type']).firstOrNull;
    final kind = ResourceKind.values.where((value) => value.name == json['kind']).firstOrNull;
    if (type == null || kind == null) throw const FormatException('Unknown resource rule type or category');
    return ResourceSnifferRule(id: id, type: type, pattern: pattern.trim(), kind: kind, enabled: enabled);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'pattern': pattern,
        'kind': kind.name,
        'enabled': enabled,
      };
}

class ResourceSnifferConfig {
  final bool enabled;
  final bool includeImages;
  final List<ResourceSnifferRule> rules;

  ResourceSnifferConfig({this.enabled = true, this.includeImages = false, List<ResourceSnifferRule> rules = const []})
      : rules = List.unmodifiable(rules);

  ResourceSnifferConfig copyWith({bool? enabled}) =>
      ResourceSnifferConfig(enabled: enabled ?? this.enabled, includeImages: includeImages, rules: rules);

  factory ResourceSnifferConfig.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'] ?? true;
    final includeImages = json['includeImages'] ?? false;
    final entries = json['rules'] ?? <dynamic>[];
    if (enabled is! bool || includeImages is! bool || entries is! List) {
      throw const FormatException('enabled/includeImages must be boolean and rules must be a list');
    }
    final rules = <ResourceSnifferRule>[];
    final ids = <String>{};
    for (final entry in entries) {
      if (entry is! Map) throw const FormatException('Every resource rule must be an object');
      final rule = ResourceSnifferRule.fromJson(Map<String, dynamic>.from(entry));
      if (!ids.add(rule.id)) throw const FormatException('Resource rule ids must be unique');
      rules.add(rule);
    }
    return ResourceSnifferConfig(enabled: enabled, includeImages: includeImages, rules: rules);
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'includeImages': includeImages,
        'rules': rules.map((rule) => rule.toJson()).toList(),
      };
}

class ResourceMatch {
  final ResourceKind kind;
  final String fileName;
  final String reason;

  const ResourceMatch(this.kind, this.fileName, this.reason);
}

/// Header-only classification. It never reads a body or requests a resource.
class ResourceClassifier {
  static const _extensions = {
    'mp3': ResourceKind.audio,
    'aac': ResourceKind.audio,
    'm4a': ResourceKind.audio,
    'wav': ResourceKind.audio,
    'ogg': ResourceKind.audio,
    'oga': ResourceKind.audio,
    'opus': ResourceKind.audio,
    'flac': ResourceKind.audio,
    'aif': ResourceKind.audio,
    'aiff': ResourceKind.audio,
    'wma': ResourceKind.audio,
    'amr': ResourceKind.audio,
    'mp4': ResourceKind.video,
    'm4v': ResourceKind.video,
    'webm': ResourceKind.video,
    'flv': ResourceKind.video,
    'f4v': ResourceKind.video,
    'mov': ResourceKind.video,
    'mkv': ResourceKind.video,
    'avi': ResourceKind.video,
    'wmv': ResourceKind.video,
    'mpeg': ResourceKind.video,
    'mpg': ResourceKind.video,
    'ogv': ResourceKind.video,
    '3gp': ResourceKind.video,
    'ts': ResourceKind.video,
    'm2ts': ResourceKind.video,
    'm4s': ResourceKind.video,
    'm3u8': ResourceKind.hls,
    'm3u': ResourceKind.hls,
    'mpd': ResourceKind.dash,
    'jpg': ResourceKind.image,
    'jpeg': ResourceKind.image,
    'png': ResourceKind.image,
    'gif': ResourceKind.image,
    'webp': ResourceKind.image,
    'avif': ResourceKind.image,
    'bmp': ResourceKind.image,
    'svg': ResourceKind.image,
    'ico': ResourceKind.image,
    'heic': ResourceKind.image,
  };

  static const _hlsMimes = {
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'application/mpegurl',
    'audio/mpegurl',
    'audio/x-mpegurl',
  };

  ResourceMatch? classify({
    required ResourceSnifferConfig config,
    required String url,
    String? mimeType,
    String? contentDisposition,
    String? cachedFileName,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null || !['http', 'https'].contains(uri.scheme.toLowerCase()) || uri.host.isEmpty) return null;
    final mime = (mimeType ?? '').split(';').first.trim().toLowerCase();
    final attachmentName = _attachmentName(contentDisposition) ??
        (contentDisposition == null && cachedFileName != null ? _safeName(cachedFileName) : null);
    final pathName = _safeName(_decode(uri.path.split('/').last));
    final fileName = attachmentName ?? (pathName.isEmpty ? uri.host : pathName);
    final extensions = [if (attachmentName != null) _extension(attachmentName), _extension(pathName)];

    for (final rule in config.rules) {
      if (rule.matches(url, mime, extensions)) {
        if (rule.kind == ResourceKind.image && !config.includeImages) return null;
        return ResourceMatch(rule.kind, fileName, 'custom:${rule.type.name}:${rule.pattern}');
      }
    }

    ResourceKind? kind;
    if (_hlsMimes.contains(mime)) {
      kind = ResourceKind.hls;
    } else if (mime == 'application/dash+xml') {
      kind = ResourceKind.dash;
    } else if (mime.startsWith('audio/') || mime == 'application/ogg') {
      kind = ResourceKind.audio;
    } else if (mime.startsWith('video/') || mime == 'application/x-flv' || mime == 'application/vnd.rn-realmedia') {
      kind = ResourceKind.video;
    } else if (mime.startsWith('image/')) {
      kind = ResourceKind.image;
    }
    if (kind != null) {
      if (kind == ResourceKind.image && !config.includeImages) return null;
      return ResourceMatch(kind, fileName, 'mime:$mime');
    }

    // An HTML/JSON error page at a media-looking URL should not become a resource.
    if (mime == 'text/html' ||
        mime == 'application/xhtml+xml' ||
        mime.endsWith('/json') ||
        mime.endsWith('+json') ||
        mime.contains('javascript') ||
        mime == 'text/css') {
      return null;
    }
    for (var index = 0; index < extensions.length; index++) {
      final extension = extensions[index];
      final candidate = _extensions[extension];
      if (candidate != null) {
        if (candidate == ResourceKind.image && !config.includeImages) return null;
        final source = attachmentName != null && index == 0 ? 'filename' : 'extension';
        return ResourceMatch(candidate, fileName, '$source:$extension');
      }
    }
    return null;
  }

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String? _attachmentName(String? value) {
    if (value == null) return null;
    final extended =
        RegExp(r'''(?:^|;)\s*filename\*\s*=\s*(?:"([^"]*)"|([^;]*))''', caseSensitive: false).firstMatch(value);
    if (extended != null) {
      final parameter = (extended.group(1) ?? extended.group(2) ?? '').trim();
      final encoded = RegExp(r"^[^']*'[^']*'(.*)$").firstMatch(parameter)?.group(1);
      if (encoded != null) {
        final name = _safeName(_decode(encoded));
        if (name.isNotEmpty) return name;
      }
    }
    final regular =
        RegExp(r'(?:^|;)\s*filename\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^;]*))', caseSensitive: false).firstMatch(value);
    if (regular == null) return null;
    final name = _safeName((regular.group(1) ?? regular.group(2) ?? '').replaceAll(r'\"', '"').trim());
    return name.isEmpty ? null : name;
  }

  static String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on FormatException {
      return value;
    }
  }

  static String _safeName(String value) =>
      value.replaceAll('\\', '/').split('/').last.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
}

/// Only scalar metadata is stored: traffic objects and response bytes are never retained.
class ResourceMetadata {
  final String url;
  final String method;
  final String fileName;
  final ResourceKind kind;
  final String? mimeType;
  final int? sizeBytes;
  final int statusCode;
  final String host;
  final String? referer;
  final String? processName;
  final String? etag;
  final String? lastModified;
  final String requestId;
  final String matchReason;
  final DateTime seenAt;

  const ResourceMetadata({
    required this.url,
    this.method = 'GET',
    required this.fileName,
    required this.kind,
    this.mimeType,
    this.sizeBytes,
    required this.statusCode,
    required this.host,
    this.referer,
    this.processName,
    this.etag,
    this.lastModified,
    required this.requestId,
    required this.matchReason,
    required this.seenAt,
  });
}

class SniffedResource {
  final String id;
  final ResourceMetadata metadata;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final int hitCount;
  final int contentRevision;

  const SniffedResource({
    required this.id,
    required this.metadata,
    required this.firstSeen,
    required this.lastSeen,
    required this.hitCount,
    this.contentRevision = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': metadata.url,
        'method': metadata.method,
        'fileName': metadata.fileName,
        'kind': metadata.kind.name,
        'mimeType': metadata.mimeType,
        'sizeBytes': metadata.sizeBytes,
        'statusCode': metadata.statusCode,
        'host': metadata.host,
        'referer': metadata.referer,
        'processName': metadata.processName,
        'firstSeen': firstSeen.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
        'hitCount': hitCount,
        'requestId': metadata.requestId,
        'matchReason': metadata.matchReason,
        'contentRevision': contentRevision,
      };
}

class ResourceSnifferStore {
  final int maxEntries;
  final LinkedHashMap<String, SniffedResource> _resources = LinkedHashMap();
  int _nextId = 0;
  int revision = 0;

  ResourceSnifferStore({this.maxEntries = 2000}) {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
  }

  int get length => _resources.length;

  SniffedResource? findByUrl(String url) => _resources[url];

  SniffedResource? findById(String id) => _resources.values.where((entry) => entry.id == id).firstOrNull;

  /// [countHit] is decided once per request by the observer, independent of header/final callbacks.
  String? record(ResourceMetadata metadata, {required bool countHit}) {
    final old = _resources[metadata.url];
    // A late final event must not resurrect an entry evicted since its headers arrived.
    if (old == null && !countHit) return null;
    final sameRequest = old?.metadata.requestId == metadata.requestId;
    // A final from another request must not become latest when two requests
    // share the same clock tick. Only its first observation or the same request
    // can replace the current metadata.
    final isLatest = old == null || ((countHit || sameRequest) && !metadata.seenAt.isBefore(old.lastSeen));
    final latest = isLatest ? _merge(metadata, old?.metadata) : old.metadata;
    final lastSeen = isLatest ? metadata.seenAt : old.lastSeen;
    final entry = SniffedResource(
      id: old?.id ?? 'resource-${++_nextId}',
      metadata: latest,
      firstSeen: old?.firstSeen ?? metadata.seenAt,
      lastSeen: lastSeen,
      hitCount: (old?.hitCount ?? 0) + (countHit ? 1 : 0),
      contentRevision: (old?.contentRevision ?? 0) + (old != null && !_sameContent(latest, old.metadata) ? 1 : 0),
    );
    _resources[metadata.url] = entry;
    String? evictedId;
    if (old == null && _resources.length > maxEntries) {
      final oldest = _resources.values.reduce((a, b) => a.lastSeen.isAfter(b.lastSeen) ? b : a);
      evictedId = oldest.id;
      _resources.remove(oldest.metadata.url);
    }
    revision++;
    return evictedId;
  }

  static ResourceMetadata _merge(ResourceMetadata current, ResourceMetadata? old) {
    final sameRequest = old?.requestId == current.requestId;
    final reuseRepresentation = sameRequest || current.statusCode == 304;
    return ResourceMetadata(
      url: current.url,
      method: current.method,
      fileName: current.fileName,
      kind: current.kind,
      mimeType: current.mimeType ?? (reuseRepresentation ? old?.mimeType : null),
      sizeBytes: current.sizeBytes ?? (reuseRepresentation ? old?.sizeBytes : null),
      statusCode: current.statusCode,
      host: current.host,
      referer: current.referer ?? (sameRequest ? old?.referer : null),
      processName: current.processName ?? (sameRequest ? old?.processName : null),
      etag: current.etag ?? (reuseRepresentation ? old?.etag : null),
      lastModified: current.lastModified ?? (reuseRepresentation ? old?.lastModified : null),
      requestId: current.requestId,
      matchReason: current.matchReason,
      seenAt: current.seenAt,
    );
  }

  static bool _sameContent(ResourceMetadata current, ResourceMetadata old) =>
      current.method == old.method &&
      current.kind == old.kind &&
      current.mimeType == old.mimeType &&
      current.sizeBytes == old.sizeBytes &&
      current.etag == old.etag &&
      current.lastModified == old.lastModified;

  void clear() {
    _resources.clear();
    revision++;
  }

  void configurationChanged() => revision++;

  List<String> get hosts => _resources.values.map((entry) => entry.metadata.host).toSet().toList()..sort();

  List<SniffedResource> matching({String keyword = '', String kind = 'all', String host = '', Set<String>? ids}) {
    final search = keyword.trim().toLowerCase();
    final domain = host.trim().toLowerCase();
    final results = _resources.values.where((entry) {
      final data = entry.metadata;
      if (ids != null && !ids.contains(entry.id)) return false;
      if (kind != 'all' && data.kind.name != kind) return false;
      if (domain.isNotEmpty && data.host.toLowerCase() != domain) return false;
      return search.isEmpty ||
          [data.url, data.fileName, data.host, data.mimeType ?? '', data.processName ?? '']
              .any((value) => value.toLowerCase().contains(search));
    }).toList();
    results.sort((a, b) {
      final time = b.lastSeen.compareTo(a.lastSeen);
      return time != 0 ? time : b.id.compareTo(a.id);
    });
    return results;
  }
}
