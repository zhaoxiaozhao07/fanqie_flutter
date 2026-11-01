import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/note_anchor_resolver.dart';
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
        .setMockMethodCallHandler(native, (_) async => null);
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null),
  );

  testWidgets(
    'only the selected repeated quotation is marked in the real reader',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const text = '重复和重复。';
      final book = Book(bookId: 'precise-note', bookName: '精确批注', author: '测试');
      await BookmarkService().addNote(
        bookId: book.bookId,
        chapterId: 'c',
        chapterIndex: 0,
        chapterTitle: '章节',
        text: '重复',
        startOffset: 3,
        endOffset: 5,
        chapterHash: NoteAnchorResolver.digest([text]),
      );
      await fixture.openReader(
        tester,
        'none',
        book: book,
        chapters: [Chapter(itemId: 'c', title: '章节', content: text)],
      );
      final textWidget = tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains(text),
        ),
      );
      final marked = <String>[];
      void walk(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.decoration == TextDecoration.underline &&
            span.text != null) {
          marked.add(span.text!);
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }

      walk(textWidget.text);
      expect(marked, ['重复']);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.settleReader(tester);
    },
  );

  testWidgets('selection toolbar saves a note with exact source offsets', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const text = '重复和重复。';
    final book = await fixture.openReader(
      tester,
      'none',
      chapters: [Chapter(itemId: 'c', title: '章节', content: text)],
    );
    final paragraph = find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains(text),
    );
    await tester.longPress(paragraph);
    await fixture.settleReader(tester);
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final value = state.widget.controller.value;
    final prefix = value.text.indexOf(text);
    state.userUpdateTextEditingValue(
      value.copyWith(
        selection: TextSelection(
          baseOffset: prefix + 3,
          extentOffset: prefix + 5,
        ),
      ),
      SelectionChangedCause.longPress,
    );
    state.showToolbar();
    await fixture.settleReader(tester);
    await tester.tap(find.text('笔记'));
    await fixture.settleReader(tester);
    await tester.enterText(find.byType(TextField).first, '第二处摘录的笔记');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await fixture.settleReader(tester);
    final notes = await BookmarkService().getNotes(book.bookId);
    expect(notes.single.text, '重复');
    expect(notes.single.startOffset, 3);
    expect(notes.single.endOffset, 5);
    expect(notes.single.note, '第二处摘录的笔记');
    expect(notes.single.chapterHash, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });
}
