import 'package:fanqie_flutter/widgets/desktop_reader_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

export 'package:fanqie_flutter/widgets/desktop_reader_selection.dart';

bool hasDesktopSelection(WidgetTester tester) => tester
    .widgetList<DesktopReaderSelection>(find.byType(DesktopReaderSelection))
    .any((area) => area.controller.hasSelection);

TextEditingValue desktopSelectionValue(WidgetTester tester, Finder paragraph) {
  final widget = tester.widget<DesktopSelectableParagraph>(paragraph);
  final listener = tester.widget<SelectionListener>(
    find.descendant(of: paragraph, matching: find.byType(SelectionListener)),
  );
  final range = listener.selectionNotifier.selection.range;
  return TextEditingValue(
    text: widget.span.toPlainText(),
    selection: range == null
        ? const TextSelection.collapsed(offset: 0)
        : TextSelection(
            baseOffset: range.startOffset,
            extentOffset: range.endOffset,
          ),
  );
}
