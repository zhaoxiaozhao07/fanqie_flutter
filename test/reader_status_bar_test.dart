import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/reader_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_navigation_test.dart' as fixture;

const native = MethodChannel('com.fanqie.fanqie_flutter/download');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          native,
          (call) async => call.method == 'getBatteryLevel' ? 73 : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  testWidgets('clock, battery and progress stay at the safe lower-right edge', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final scale in [1.0, 2.0, 3.2]) {
        const insets = EdgeInsets.only(top: 24, right: 28, bottom: 24);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                padding: insets,
                viewPadding: insets,
                textScaler: TextScaler.linear(scale),
              ),
              child: const Scaffold(
                body: SafeArea(
                  child: Column(
                    children: [
                      Expanded(child: SizedBox()),
                      ReaderStatusBar(
                        chapterLabel: '一个很长的章节名称，只能挤压左侧标签，不能挤走电量信息',
                        clockLabel: '21:09 · 100%',
                        clockSemantics: '时间 21:09，电量 100%',
                        progressLabel: '100.0%',
                        progressSemantics: '约完成 100.0%',
                        backgroundColor: Colors.white,
                        textColor: Colors.grey,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final group = tester.getRect(
          find.byKey(const ValueKey('reader-status-info')),
        );
        final footer = tester.getRect(
          find.byKey(const ValueKey('reader-status-bar')),
        );
        expect(group.right, closeTo(size.width - insets.right - 16, .01));
        expect(footer.bottom, closeTo(size.height - insets.bottom, .01));
        expect(group.center.dy, greaterThan(size.height - insets.bottom - 45));
        expect(tester.takeException(), isNull);
      }
    }
  });

  for (final pageMode in [false, true]) {
    testWidgets(
      '${pageMode ? 'paged' : 'scroll'} reader anchors status info at the right edge',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        await ReaderSettingsRepository().save(
          ReaderSettings(pageMode: pageMode, commentBubbles: false),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderScreen(
              book: Book(
                bookId: 'footer-$pageMode',
                bookName: '状态栏测试',
                author: '测试',
              ),
              resumeSavedPosition: false,
              chapters: [
                Chapter(
                  itemId: 'footer-$pageMode-1',
                  title: '第一章',
                  content: fixture.chapterText(0, paragraphs: 20),
                ),
              ],
            ),
          ),
        );
        for (var i = 0; i < 15; i++) {
          await fixture.settleReader(tester);
        }
        expect(
          find.byType(ReaderPageView),
          pageMode ? findsOneWidget : findsNothing,
        );
        // Desktop deliberately has no Android battery provider; the standalone
        // geometry test covers battery text and the device test covers its API.
        expect(
          RegExp(r'^\d{2}:\d{2}').hasMatch(
            tester
                .widget<ReaderStatusBar>(find.byType(ReaderStatusBar))
                .clockLabel,
          ),
          isTrue,
        );
        final group = tester.getRect(
          find.byKey(const ValueKey('reader-status-info')),
        );
        expect(group.right, closeTo(304, .01));
        expect(group.center.dy, greaterThan(600));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await fixture.settleReader(tester);
      },
    );
  }
}
