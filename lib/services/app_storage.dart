import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'reader_platform.dart';

/// All durable reading data uses the same platform-specific root.
/// Android's established Documents layout is intentionally not migrated.
class AppStorage {
  @visibleForTesting
  static Future<Directory> Function()? documentsOverride;

  static Future<Directory> documents() async {
    if (documentsOverride != null) return documentsOverride!();
    if (ReaderPlatform.isMacOS) {
      final root = await getApplicationSupportDirectory();
      await root.create(recursive: true);
      return root;
    }
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      // Preserve the existing non-desktop test/legacy behavior only.
      return Directory.systemTemp;
    }
  }
}
