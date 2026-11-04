import 'dart:ui' as ui;
import 'package:fanqie_flutter/widgets/book_page_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'book entry paints opaque pages without fading/zooming cached snapshots',
    (tester) async {
      final key = GlobalKey();
      final navigator = GlobalKey<NavigatorState>();
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(backgroundColor: Colors.red),
          ),
        ),
      );
      final route = BookPageRoute<void>(
        builder: (_) => const Scaffold(backgroundColor: Colors.blue),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(route.allowSnapshotting, false);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final colors = <int>{};
        for (var x = 0; x < 400; x += 10) {
          colors.add(bytes.getUint32((400 * 400 + x) * 4));
        }
        expect(colors, {
          0xf44336ff,
          0x2196f3ff,
        }); // Material red and blue, no mixed ghost pixels.
        image.dispose();
      });
      await tester.pumpAndSettle();
      expect(route.isCurrent, true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
