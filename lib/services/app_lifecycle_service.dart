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
import 'reader_platform.dart';
import 'desktop_reader_preferences.dart';
import 'external_book_import_service.dart';
import 'reader_auto_backup_service.dart';
import 'reader_trash_service.dart';

/// Native Cmd-Q waits for pending anchors/settings, not just widget disposal.
class AppLifecycleService {
  static void initialize() {
    ReaderSystemService.registerQuitHandler(prepareToQuit);
    ReaderSystemService.registerWindowHiddenHandler(() async {
      await ReaderAutoBackupService().runDue().catchError((_) => null);
    });
    ReaderSystemService.registerDesktopCommandHandler(DesktopCommands.dispatch);
  }

  static Future<bool> prepareToQuit() async {
    if (ReaderBackupService.hasActiveTransaction ||
        LocalBookService.hasActiveCommit) {
      return false;
    }
    try {
      if (!await ExternalBookImportService().canQuit()) return false;
      await ReaderSystemService.flushParticipants();
      await ReaderAutoBackupService().runDue().catchError((_) => null);
      await ReaderBackupService.flushCreates();
      final tts = TtsService();
      if (tts.isAvailable && tts.isActive) await tts.stop();
      await (ReaderPlatform.isMacOS
              ? DownloadService().prepareToQuit()
              : DownloadService().cancelAllAndWait())
          .timeout(const Duration(seconds: 6));
      await BookmarkService().flush();
      await ReaderTrashService().flush();
      await ReaderPositionService.flush();
      await ReaderSettingsRepository.flush();
      await DesktopReaderPreferences.flush();
      await ReadingActivityService().flush();
      await ExternalBookImportService().releasePending();
      return !ReaderBackupService.hasActiveTransaction &&
          !LocalBookService.hasActiveCommit;
    } catch (_) {
      return false;
    }
  }
}
