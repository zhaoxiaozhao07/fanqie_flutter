import 'package:flutter/material.dart';
import '../services/reader_trash_service.dart';
import '../services/reader_trash_coordinator.dart';

void showReaderUndo(
  BuildContext context,
  String message,
  List<ReaderTrashEntry> entries,
) {
  if (!context.mounted || entries.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          try {
            for (final entry in entries.reversed) {
              await ReaderTrashCoordinator.restore(entry);
            }
            messenger.showSnackBar(const SnackBar(content: Text('已撤销，原文位置保留')));
          } catch (_) {
            messenger.showSnackBar(
              const SnackBar(content: Text('存在后续修改或保存失败，未覆盖新记录；旧版本仍可在回收站查看')),
            );
          }
        },
      ),
    ),
  );
}
