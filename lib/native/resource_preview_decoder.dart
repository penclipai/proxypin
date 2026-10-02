import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:media_kit/media_kit.dart';
import 'package:proxypin/network/components/resource_sniffer/resource_preview.dart';

/// A small lifecycle seam for testing cancellation without loading a native DLL.
abstract interface class ResourceMediaSession {
  Future<Map<String, dynamic>> capture(Uri bridge);
  Future<void> dispose();
}

/// Decoders receive only bounded bytes or a temporary loopback media bridge.
/// Remote URLs and authentication headers remain in the main window service.
class ResourcePreviewDecoder {
  static const _maximumDimension = 8192;
  static const _maximumPixels = 16 * 1024 * 1024;
  static const _thumbnailSize = 768;
  static final _active = <Uri, _MediaDecodeJob>{};

  static Future<Map<String, dynamic>> decode(Uri url,
      {ResourceMediaSession Function()? createSession, Duration timeout = const Duration(seconds: 18)}) async {
    if (url.scheme != 'http' || url.host != '127.0.0.1' || !url.hasPort || url.port <= 0 || url.userInfo.isNotEmpty) {
      throw const FormatException('Media decoder requires a local preview bridge');
    }
    if (_active.containsKey(url) || _active.length >= 2) {
      throw const ResourcePreviewException('busy', 'Another media preview is still closing');
    }
    _MediaDecodeJob? job;
    try {
      job = _MediaDecodeJob((createSession ?? _MpvMediaSession.new)());
      _active[url] = job;
      return await Future.any([job.session.capture(url), job.cancelled.future]).timeout(timeout);
    } on ResourcePreviewException {
      rethrow;
    } on TimeoutException {
      throw const ResourcePreviewException('timeout', 'The media preview exceeded its time limit',
          diagnostics: {'stage': 'firstFrame'});
    } catch (_) {
      // Decoder errors can contain the URL and native logs. Only fixed, safe
      // diagnostics are returned to the child window.
      throw const ResourcePreviewException('decodeFailed', 'The media could not be decoded',
          diagnostics: {'stage': 'mediaDecode'});
    } finally {
      if (job != null) {
        final closingJob = job;
        final closing = job.close().then((_) {
          if (identical(_active[url], closingJob)) _active.remove(url);
        }, onError: (Object _, StackTrace __) {
          // A failed native cleanup leaves its bounded slot occupied; its
          // outcome must not replace the preview result or create more players.
        });
        try {
          await closing.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // Return promptly, but keep the slot occupied until native cleanup
          // really completes. Future.timeout does not cancel its source.
        }
      }
    }
  }

  static void cancel(Uri url) {
    final job = _active[url];
    if (job == null || job.cancelled.isCompleted) return;
    job.cancelled.completeError(const ResourcePreviewException('cancelled', 'Resource preview was cancelled'));
    unawaited(job.close().catchError((Object _) {}));
  }

  static Future<Map<String, dynamic>> decodeImage(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Image exceeds the preview size limit');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 ||
          height <= 0 ||
          width > _maximumDimension ||
          height > _maximumDimension ||
          width * height > _maximumPixels) {
        throw const FormatException('Image dimensions exceed the preview limit');
      }
      final scale = math.min(1.0, _thumbnailSize / math.max(width, height));
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).round()),
        targetHeight: math.max(1, (height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('Unable to encode the preview image');
      return {
        'imageBytes': png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        'width': width,
        'height': height,
      };
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

class _MediaDecodeJob {
  final ResourceMediaSession session;
  final cancelled = Completer<Map<String, dynamic>>();
  Future<void>? _closing;

  _MediaDecodeJob(this.session);

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async => session.dispose();
}

/// libmpv/FFmpeg supplies demuxing, codec detection and first-frame decoding.
/// No remote URL is passed to it, and nested media references are disabled.
class _MpvMediaSession implements ResourceMediaSession {
  late final Player _player;
  bool _disposed = false;

  _MpvMediaSession() {
    try {
      if (!Platform.isWindows) throw UnsupportedError('Windows preview only');
      final directory = File(Platform.resolvedExecutable).parent.path;
      MediaKit.ensureInitialized(libmpv: '$directory${Platform.pathSeparator}libmpv-2.dll');
      _player = Player(
          configuration: const PlayerConfiguration(
              vo: 'null', muted: true, bufferSize: 1024 * 1024, protocolWhitelist: ['http', 'tcp']));
    } catch (_) {
      throw const ResourcePreviewException('codecUnavailable', 'The media preview component could not be loaded',
          diagnostics: {'stage': 'mediaDecode'});
    }
  }

  @override
  Future<Map<String, dynamic>> capture(Uri bridge) async {
    final native = _player.platform as NativePlayer;
    var failed = false;
    final errors = _player.stream.error.listen((_) => failed = true);
    try {
      const settings = {
        'access-references': 'no',
        'load-unsafe-playlists': 'no',
        'cache': 'no',
        'cache-on-disk': 'no',
        'demuxer-readahead-secs': '0',
        'stream-lavf-o': 'http_proxy=[],protocol_whitelist=[http,tcp]',
        'demuxer-lavf-o':
            'http_proxy=[],protocol_whitelist=[http,tcp],format_whitelist=[mov,matroska,avi,flv,live_flv,mpegts,mpeg,mpegvideo,aac,mp3,ogg,flac,wav,asf]',
        'audio-file-auto': 'no',
        'sub-auto': 'no',
        'ao': 'null',
        'mute': 'yes',
        'hwdec': 'no',
        'vd-lavc-o': 'max_pixels=16777216',
        'vd-lavc-threads': '2',
      };
      for (final entry in settings.entries) {
        await native.setProperty(entry.key, entry.value);
      }
      for (final option in ['access-references', 'load-unsafe-playlists']) {
        if (await native.getProperty(option) != 'no') {
          throw const ResourcePreviewException('unsupported', 'The media component cannot disable external references',
              diagnostics: {'stage': 'mediaDecode'});
        }
      }
      // Keep the audio track selected for metadata/preroll. Selecting no
      // streams ends audio-only files before their metadata can be read.
      // The null audio output, mute and pause prevent audible playback.
      await _player.setAudioTrack(AudioTrack.auto());
      await _player.setVideoTrack(VideoTrack.auto());
      // Player.open builds a temporary playlist. Load the sole bridge directly
      // so load-unsafe-playlists can stay disabled. Playback remains paused.
      await native.setProperty('pause', 'yes');
      await native.command(['loadfile', bridge.toString(), 'replace']);
      while (!_disposed) {
        final state = _player.state;
        final video = state.tracks.video
            .where((track) => track.id != 'auto' && track.id != 'no' && track.albumart != true)
            .toList();
        final audio = state.tracks.audio.where((track) => track.id != 'auto' && track.id != 'no').toList();
        final metadata = <String, dynamic>{
          if (state.duration > Duration.zero) 'durationMs': state.duration.inMilliseconds,
          if (video.isNotEmpty && video.first.codec != null) 'codec': video.first.codec,
          if (video.isNotEmpty && video.first.fps != null) 'frameRate': video.first.fps,
          if (video.isNotEmpty && video.first.bitrate != null) 'bitrate': video.first.bitrate,
        };
        if (state.width != null && state.height != null) {
          if (state.width! > 8192 || state.height! > 8192 || state.width! * state.height! > 16 * 1024 * 1024) {
            throw const ResourcePreviewException('decodeFailed', 'Video dimensions exceed the preview limit',
                diagnostics: {'stage': 'firstFrame'});
          }
          final bytes = await _player.screenshot(format: 'image/png');
          if (bytes != null) {
            return {
              ...metadata,
              ...await ResourcePreviewDecoder.decodeImage(bytes),
              'width': state.width,
              'height': state.height,
            };
          }
        } else if (video.isEmpty && audio.isNotEmpty) {
          return {
            ...metadata,
            'codec': audio.first.codec,
            if (audio.first.bitrate != null) 'bitrate': audio.first.bitrate
          };
        }
        if (failed) {
          throw const ResourcePreviewException('decodeFailed', 'The media could not be decoded',
              diagnostics: {'stage': 'sourceOpen'});
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      throw const ResourcePreviewException('cancelled', 'Resource preview was cancelled');
    } finally {
      await errors.cancel();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _player.dispose();
  }
}
