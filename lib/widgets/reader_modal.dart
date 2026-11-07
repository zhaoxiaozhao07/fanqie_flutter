import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/reader_platform.dart';

/// A modal Future completes at pop, before its closing animation unmounts text
/// fields. Dispose their controllers only when the widget is actually removed.
class ReaderModalLifetime extends StatefulWidget {
  final VoidCallback onDispose;
  final Widget child;
  const ReaderModalLifetime({
    super.key,
    required this.onDispose,
    required this.child,
  });
  @override
  State<ReaderModalLifetime> createState() => _ReaderModalLifetimeState();
}

class _ReaderModalLifetimeState extends State<ReaderModalLifetime> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Desktop dialogs keep their focus inside the panel and do not resize the
/// reading viewport. Touch devices retain the existing bottom-sheet workflow.
Future<T?> showReaderModal<T>({
  required BuildContext context,
  required Color backgroundColor,
  required WidgetBuilder builder,
  double heightFactor = .85,
  double desktopWidth = 640,
}) {
  if (ReaderPlatform.isMacOS) {
    return showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .12),
      builder: (context) => Dialog(
        key: const ValueKey('desktop-reader-dialog'),
        backgroundColor: backgroundColor,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: desktopWidth,
          height: math.min(
            800,
            MediaQuery.sizeOf(context).height * heightFactor,
          ),
          child: Builder(builder: builder),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: .12),
    backgroundColor: backgroundColor,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(
        heightFactor: heightFactor,
        child: Builder(builder: builder),
      ),
    ),
  );
}
