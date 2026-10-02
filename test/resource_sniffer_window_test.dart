import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:screen_retriever/screen_retriever.dart';

const preferred = Size(1280, 800);
const primary = Display(
  id: 'primary',
  size: Size(1920, 1080),
  visibleSize: Size(1920, 1040),
  visiblePosition: Offset.zero,
  scaleFactor: 1,
);
const right = Display(
  id: 'right',
  size: Size(1280, 720),
  visibleSize: Size(1280, 1040 / 1.5),
  visiblePosition: Offset(1280, 0),
  scaleFactor: 1.5,
);

Rect physical(Rect bounds, double ratio) =>
    Rect.fromLTWH(bounds.left * ratio, bounds.top * ratio, bounds.width * ratio, bounds.height * ratio);

void expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.001));
  expect(actual.top, closeTo(expected.top, 0.001));
  expect(actual.width, closeTo(expected.width, 0.001));
  expect(actual.height, closeTo(expected.height, 0.001));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('physical monitor selection is independent of the child engine DPI', () {
    for (final ratio in [1.0, 1.5, 2.0]) {
      final bounds = resourceSnifferWindowBounds(
        preferred,
        primary: primary,
        displays: [primary, right],
        cursor: const Offset(2200, 200) / ratio,
        devicePixelRatio: ratio,
      );
      // The logical rectangles overlap, but the physical cursor is on the
      // second monitor. It must fit that monitor with a 16 logical-pixel edge.
      expectRect(physical(bounds, ratio), const Rect.fromLTWH(1944, 24, 1872, 992));
    }
  });

  test('a 150 percent child on the primary monitor keeps the intended size', () {
    final bounds = resourceSnifferWindowBounds(
      preferred,
      primary: primary,
      displays: [primary, right],
      cursor: const Offset(100, 100) / 1.5,
      devicePixelRatio: 1.5,
    );
    expectRect(physical(bounds, 1.5), const Rect.fromLTWH(320, 120, 1280, 800));
  });

  test('negative monitor origins retain their physical work area', () {
    const left = Display(
      id: 'left',
      size: Size(1536, 864),
      visibleSize: Size(1536, 832),
      visiblePosition: Offset(-1536, 0),
      scaleFactor: 1.25,
    );
    final bounds = resourceSnifferWindowBounds(
      preferred,
      primary: primary,
      displays: [primary, left],
      cursor: const Offset(-1000, 200) / 1.5,
      devicePixelRatio: 1.5,
    );
    expectRect(physical(bounds, 1.5), const Rect.fromLTWH(-1760, 20, 1600, 1000));
  });

  test('missing optional display fields fall back to the full primary area', () {
    const display = Display(id: 'fallback', size: Size(1024, 768));
    final bounds = resourceSnifferWindowBounds(
      preferred,
      primary: display,
      displays: [],
      cursor: const Offset(4000, 4000),
      devicePixelRatio: 1,
    );
    expectRect(bounds, const Rect.fromLTWH(16, 16, 992, 736));
  });

  test('small work areas are not exceeded by an artificial minimum size', () {
    const display = Display(
      id: 'small',
      size: Size(300, 240),
      visibleSize: Size(300, 200),
      visiblePosition: Offset(0, -240),
      scaleFactor: 2,
    );
    final bounds = resourceSnifferWindowBounds(
      preferred,
      primary: display,
      displays: [display],
      cursor: const Offset(100, -400),
      devicePixelRatio: 1,
    );
    expectRect(bounds, const Rect.fromLTWH(32, -448, 536, 336));
  });
}
