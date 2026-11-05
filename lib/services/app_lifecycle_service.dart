import 'bookmark_service.dart';
import 'download_service.dart';
import 'local_book_service.dart';
import 'reader_backup_service.dart';
import 'reader_position_service.dart';
import 'reader_settings_repository.dart';
import 'reader_system_service.dart';
import 'reading_activity_service.dart';
import 'tts_service.dart';
import 'desktop_commands.dart';

/// Native Cmd-Q waits for pending anchors/settings, not just widget disposal.
class AppLifecycleService {
  static void initialize() {
    ReaderSystemService.registerQuitHandler(prepareToQuit);
    ReaderSystemService.registerDesktopCommandHandler(DesktopCommands.dispatch);
  }

  static Future<bool> prepareToQuit() async {
    if (ReaderBackupService.hasActiveTransaction ||
        LocalBookService.hasActiveCommit) {
      return false;
    }
    try {
      await ReaderSystemService.flushParticipants();
      final tts = TtsService();
      if (tts.isAvailable && tts.isActive) await tts.stop();
      await DownloadService().cancelAllAndWait().timeout(
        const Duration(seconds: 6),
      );
      await BookmarkService().flush();
      await ReaderPositionService.flush();
      await ReaderSettingsRepository.flush();
      await ReadingActivityService().flush();
      return !ReaderBackupService.hasActiveTransaction &&
          !LocalBookService.hasActiveCommit;
    } catch (_) {
      return false;
    }
  }
}
