import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/components/stream_code/stream_code_data.dart';
import 'package:proxypin/network/http/http.dart';

Map<String, dynamic> _apiResponse(String rtmpUrl) => {
      'stream_url': {'rtmp_push_url': rtmpUrl},
      'id_str': '7123456789012345678',
      'id': 42,
      'title': 'Test live room',
      'cover': {
        'url_list': ['', 'https://example.com/cover.jpg', 'https://example.com/cover-backup.jpg'],
      },
      'owner': {
        'nickname': 'Test account',
        'short_id': 12345678,
        'avatar_thumb': {
          'url_list': ['', 'https://example.com/avatar.jpg', 'https://example.com/avatar-backup.jpg'],
        },
      },
    };

HttpRequest _request(String url) => HttpRequest(HttpMethod.post, url)
  ..headers.set('Cookie', 'session_id=test-session')
  ..headers.set('User-Agent', 'stream-code-test')
  ..body = utf8.encode('room_id=7123456789&title=直播');

void main() {
  group('StreamCodeData', () {
    const validRtmpUrl = 'rtmp://push-rtmp-l3.douyincdn.com/stage/stream-123456?auth_key=abc&expires=123';
    const validRequestUrl = 'https://webcast5-mate-lf.amemv.com/webcast/room/get_latest_room/?room_id=7123456789';

    test('fromApiResponse with valid URL should split correctly', () {
      final request = _request(validRequestUrl);
      final data = StreamCodeData.fromApiResponse(_apiResponse(validRtmpUrl), request);

      expect(data.rtmpPushUrl, equals(validRtmpUrl));
      expect(data.pushAddress, equals('rtmp://push-rtmp-l3.douyincdn.com/stage/'));
      expect(data.streamKey, equals('stream-123456?auth_key=abc&expires=123'));
      expect(data.requestUrl, equals(validRequestUrl));
      expect(data.capturedAt, isA<DateTime>());
      expect(data.originalRequest, same(request));
      expect(data.roomTitle, 'Test live room');
      expect(data.coverImageUrl, 'https://example.com/cover.jpg');
      expect(data.accountNickname, 'Test account');
      expect(data.accountAvatarUrl, 'https://example.com/avatar.jpg');
      expect(data.accountShortId, '12345678');
      expect(data.roomId, '7123456789012345678');
    });

    test('fromApiResponse without "stream-" separator should throw FormatException', () {
      const invalidUrl = 'rtmp://push-rtmp-l3.douyincdn.com/stage/invalid-url';

      expect(
        () => StreamCodeData.fromApiResponse(_apiResponse(invalidUrl), _request(validRequestUrl)),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('missing "stream-" separator'),
        )),
      );
    });

    test('fromApiResponse requires a non-empty RTMP push URL', () {
      for (final response in <Map<String, dynamic>>[
        {},
        {'stream_url': <String, dynamic>{}},
        {
          'stream_url': {'rtmp_push_url': ''}
        },
      ]) {
        expect(
          () => StreamCodeData.fromApiResponse(response, _request(validRequestUrl)),
          throwsA(isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Missing rtmp_push_url'),
          )),
        );
      }
    });

    test('fromApiResponse tolerates missing account data and falls back to numeric room ID', () {
      final data = StreamCodeData.fromApiResponse({
        'stream_url': {'rtmp_push_url': validRtmpUrl},
        'id': 12345,
        'cover': {'url_list': <String>[]},
      }, _request(validRequestUrl));

      expect(data.roomId, '12345');
      expect(data.roomTitle, isNull);
      expect(data.coverImageUrl, isNull);
      expect(data.accountNickname, isNull);
      expect(data.accountAvatarUrl, isNull);
      expect(data.accountShortId, isNull);
    });

    test('toJson and fromJson should preserve data', () {
      final capturedTime = DateTime.parse('2025-11-03T10:30:45.123Z');
      final request = _request(validRequestUrl);
      final original = StreamCodeData(
        rtmpPushUrl: validRtmpUrl,
        pushAddress: 'rtmp://push-rtmp-l3.douyincdn.com/stage/',
        streamKey: 'stream-123456?auth_key=abc&expires=123',
        capturedAt: capturedTime,
        requestUrl: validRequestUrl,
        originalRequest: request,
        roomTitle: 'Test live room',
        coverImageUrl: 'https://example.com/cover.jpg',
        accountNickname: 'Test account',
        accountAvatarUrl: 'https://example.com/avatar.jpg',
        accountShortId: '12345678',
        roomId: '7123456789012345678',
      );

      final json = original.toJson();
      final restored = StreamCodeData.fromJson(json);

      expect(restored.rtmpPushUrl, equals(original.rtmpPushUrl));
      expect(restored.pushAddress, equals(original.pushAddress));
      expect(restored.streamKey, equals(original.streamKey));
      expect(restored.capturedAt, equals(original.capturedAt));
      expect(restored.requestUrl, equals(original.requestUrl));
      expect(restored.originalRequest, isNotNull);
      expect(restored.originalRequest!.requestUrl, request.requestUrl);
      expect(restored.originalRequest!.method, request.method);
      expect(restored.originalRequest!.headers.get('Cookie'), request.headers.get('Cookie'));
      expect(restored.originalRequest!.headers.get('User-Agent'), request.headers.get('User-Agent'));
      expect(restored.originalRequest!.body, request.body);
      expect(restored.roomTitle, original.roomTitle);
      expect(restored.coverImageUrl, original.coverImageUrl);
      expect(restored.accountNickname, original.accountNickname);
      expect(restored.accountAvatarUrl, original.accountAvatarUrl);
      expect(restored.accountShortId, original.accountShortId);
      expect(restored.roomId, original.roomId);
    });

    test('equality operator should compare by rtmpPushUrl and capturedAt', () {
      final time1 = DateTime.parse('2025-11-03T10:30:45.123Z');
      final time2 = DateTime.parse('2025-11-03T10:30:45.123Z');
      final time3 = DateTime.parse('2025-11-03T10:35:00.000Z');

      final data1 = StreamCodeData(
        rtmpPushUrl: validRtmpUrl,
        pushAddress: 'rtmp://push-rtmp-l3.douyincdn.com/stage/',
        streamKey: 'stream-123456?auth_key=abc&expires=123',
        capturedAt: time1,
        requestUrl: validRequestUrl,
      );

      final data2 = StreamCodeData(
        rtmpPushUrl: validRtmpUrl,
        pushAddress: 'rtmp://push-rtmp-l3.douyincdn.com/stage/',
        streamKey: 'stream-123456?auth_key=abc&expires=123',
        capturedAt: time2,
        requestUrl: validRequestUrl,
      );

      final data3 = StreamCodeData(
        rtmpPushUrl: validRtmpUrl,
        pushAddress: 'rtmp://push-rtmp-l3.douyincdn.com/stage/',
        streamKey: 'stream-123456?auth_key=abc&expires=123',
        capturedAt: time3,
        requestUrl: validRequestUrl,
      );

      expect(data1, equals(data2)); // Same time
      expect(data1, isNot(equals(data3))); // Different time
    });

    test('hashCode should be consistent with equality', () {
      final time = DateTime.parse('2025-11-03T10:30:45.123Z');

      final data1 = StreamCodeData(
        rtmpPushUrl: validRtmpUrl,
        pushAddress: 'rtmp://push-rtmp-l3.douyincdn.com/stage/',
        streamKey: 'stream-123456?auth_key=abc&expires=123',
        capturedAt: time,
        requestUrl: validRequestUrl,
      );

      final data2 = StreamCodeData(
        rtmpPushUrl: validRtmpUrl,
        pushAddress: 'rtmp://push-rtmp-l3.douyincdn.com/stage/',
        streamKey: 'stream-123456?auth_key=abc&expires=123',
        capturedAt: time,
        requestUrl: validRequestUrl,
      );

      expect(data1.hashCode, equals(data2.hashCode));
    });

    test('toString should include key fields', () {
      final data = StreamCodeData.fromApiResponse(_apiResponse(validRtmpUrl), _request(validRequestUrl));
      final str = data.toString();

      expect(str, contains('pushAddress'));
      expect(str, contains('streamKey'));
      expect(str, contains('capturedAt'));
    });
  });

  group('StreamCodeSettings', () {
    test('default constructor should have correct defaults', () {
      final settings = StreamCodeSettings();

      expect(settings.autoExtractEnabled, isFalse);
      expect(settings.lastStreamCode, isNull);
    });

    test('toJson and fromJson with null lastStreamCode should preserve data', () {
      final original = StreamCodeSettings(
        autoExtractEnabled: true,
        lastStreamCode: null,
      );

      final json = original.toJson();
      final restored = StreamCodeSettings.fromJson(json);

      expect(restored.autoExtractEnabled, isTrue);
      expect(restored.lastStreamCode, isNull);
    });

    test('toJson and fromJson with valid lastStreamCode should preserve nested data', () {
      final streamCodeData = StreamCodeData.fromApiResponse(
        _apiResponse('rtmp://push-rtmp-l3.douyincdn.com/stage/stream-123456?auth_key=abc'),
        _request('https://webcast5-mate-lf.amemv.com/webcast/room/get_latest_room/?room_id=123'),
      );

      final original = StreamCodeSettings(
        autoExtractEnabled: true,
        lastStreamCode: streamCodeData,
      );

      final json = original.toJson();
      final restored = StreamCodeSettings.fromJson(json);

      expect(restored.autoExtractEnabled, isTrue);
      expect(restored.lastStreamCode, isNotNull);
      expect(restored.lastStreamCode!.rtmpPushUrl, equals(streamCodeData.rtmpPushUrl));
      expect(restored.lastStreamCode!.pushAddress, equals(streamCodeData.pushAddress));
      expect(restored.lastStreamCode!.streamKey, equals(streamCodeData.streamKey));
      expect(restored.lastStreamCode!.requestUrl, equals(streamCodeData.requestUrl));
      expect(restored.lastStreamCode!.originalRequest!.toJson(), streamCodeData.originalRequest!.toJson());
      expect(restored.lastStreamCode!.accountNickname, streamCodeData.accountNickname);
      expect(restored.lastStreamCode!.accountAvatarUrl, streamCodeData.accountAvatarUrl);
      expect(restored.lastStreamCode!.accountShortId, streamCodeData.accountShortId);
      expect(restored.lastStreamCode!.roomId, streamCodeData.roomId);
    });

    test('fromJson with missing autoExtractEnabled should default to false', () {
      final json = <String, dynamic>{};
      final settings = StreamCodeSettings.fromJson(json);

      expect(settings.autoExtractEnabled, isFalse);
      expect(settings.lastStreamCode, isNull);
    });

    test('toString should indicate presence of lastStreamCode', () {
      final settingsWithoutData = StreamCodeSettings();
      final settingsWithData = StreamCodeSettings(
        autoExtractEnabled: true,
        lastStreamCode: StreamCodeData.fromApiResponse(
          _apiResponse('rtmp://push-rtmp-l3.douyincdn.com/stage/stream-123?auth_key=abc'),
          _request('https://webcast5-mate-lf.amemv.com/webcast/room/get_latest_room/?room_id=123'),
        ),
      );

      expect(settingsWithoutData.toString(), contains('hasLastStreamCode: false'));
      expect(settingsWithData.toString(), contains('hasLastStreamCode: true'));
    });
  });

  group('JSON Edge Cases', () {
    test('legacy StreamCodeData JSON without replay request or account fields remains readable', () {
      final data = StreamCodeData.fromJson({
        'rtmpPushUrl': 'rtmp://test/stream-123',
        'pushAddress': 'rtmp://test/',
        'streamKey': 'stream-123',
        'capturedAt': '2025-11-03T10:30:45.123Z',
        'requestUrl': 'https://example.com/get_latest_room',
      });

      expect(data.streamKey, 'stream-123');
      expect(data.originalRequest, isNull);
      expect(data.roomTitle, isNull);
      expect(data.coverImageUrl, isNull);
      expect(data.accountNickname, isNull);
      expect(data.accountAvatarUrl, isNull);
      expect(data.accountShortId, isNull);
      expect(data.roomId, isNull);
    });

    test('StreamCodeData fromJson with invalid capturedAt should throw', () {
      final invalidJson = {
        'rtmpPushUrl': 'rtmp://test/stream-123',
        'pushAddress': 'rtmp://test/',
        'streamKey': 'stream-123',
        'capturedAt': 'invalid-date-format',
        'requestUrl': 'https://test.com',
      };

      expect(
        () => StreamCodeData.fromJson(invalidJson),
        throwsA(isA<FormatException>()),
      );
    });

    test('StreamCodeSettings fromJson with null lastStreamCode field should work', () {
      final json = {
        'autoExtractEnabled': true,
        'lastStreamCode': null,
      };

      final settings = StreamCodeSettings.fromJson(json);
      expect(settings.autoExtractEnabled, isTrue);
      expect(settings.lastStreamCode, isNull);
    });
  });
}
