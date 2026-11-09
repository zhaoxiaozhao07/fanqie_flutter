import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/material.dart';
import 'search_screen.dart';
import 'bookshelf_screen.dart';
import 'history_screen.dart';
import '../widgets/tts_player_panel.dart';
import '../widgets/local_book_import_dialog.dart';
import '../widgets/reader_settings_sheet.dart';
import '../services/desktop_commands.dart';
import '../services/reader_platform.dart';
import '../services/reader_settings_repository.dart';
import '../services/external_book_import_service.dart';
import 'notes_workspace_screen.dart';

/// 主页面 - 底部三导航：主页、书架、历史
class MainScreen extends StatefulWidget {
  final ExternalBookImportService? externalImports;
  const MainScreen({super.key, this.externalImports});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final _searchFocus = FocusNode(debugLabel: 'desktop-library-search');
  bool _dialogOpen = false;
  bool _externalScheduled = false;
  late final _externalImports =
      widget.externalImports ?? ExternalBookImportService();

  final GlobalKey<BookshelfScreenState> _bookshelfKey =
      GlobalKey<BookshelfScreenState>();
  final GlobalKey<HistoryScreenState> _historyKey =
      GlobalKey<HistoryScreenState>();
  final _notesKey = GlobalKey<NotesWorkspaceScreenState>();

  @override
  void initState() {
    super.initState();
    if (ReaderPlatform.isMacOS) {
      DesktopCommands.register(this, _desktopCommand);
      _externalImports.addListener(_onExternalImports);
      _onExternalImports();
    }
  }

  @override
  void dispose() {
    DesktopCommands.register(this, null);
    _externalImports.removeListener(_onExternalImports);
    _searchFocus.dispose();
    super.dispose();
  }

  void _select(int index) {
    setState(() => _currentIndex = index);
    if (index == 2) _historyKey.currentState?.refreshHistory();
  }

  bool _desktopCommand(String command) {
    if (!mounted) return false;
    if (_dialogOpen) return true;
    switch (command) {
      case 'find':
        if (_currentIndex == 1) {
          _bookshelfKey.currentState?.focusSearch();
          return true;
        }
        if (_currentIndex == 3) {
          _notesKey.currentState?.focusSearch();
          return true;
        }
        Navigator.of(context).popUntil((route) => route.isFirst);
        _select(0);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
        return true;
      case 'import':
        unawaited(_import());
        return true;
      case 'settings':
        unawaited(_settings());
        return true;
      case 'notes':
        Navigator.of(context).popUntil((route) => route.isFirst);
        _select(3);
        return true;
      default:
        return false;
    }
  }

  Future<void> _import() async {
    _dialogOpen = true;
    try {
      final result = await showDialog(
        context: context,
        builder: (_) => const LocalBookImportDialog(),
      );
      if (result != null && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        _select(1);
      }
    } finally {
      _dialogOpen = false;
      _onExternalImports();
    }
  }

  void _onExternalImports() {
    if (!mounted ||
        _dialogOpen ||
        _externalScheduled ||
        _externalImports.pendingCount == 0) {
      return;
    }
    _externalScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _externalScheduled = false;
      if (mounted && !_dialogOpen) unawaited(_presentExternalImport());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _presentExternalImport() async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
    final request = _externalImports.takeNext();
    if (request == null) {
      _dialogOpen = false;
      return;
    }
    try {
      final result = await showDialog(
        context: context,
        builder: (_) => LocalBookImportDialog(
          initialFile: request.filePath == null
              ? null
              : File(request.filePath!),
          initialError: request.error,
          autoPreview: true,
        ),
      );
      if (result != null && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        _select(1);
      }
    } finally {
      await _externalImports.complete(request);
      _dialogOpen = false;
      _onExternalImports();
    }
  }

  Future<void> _settings() async {
    _dialogOpen = true;
    try {
      final record = await ReaderSettingsRepository().load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: SizedBox(
            width: 720,
            height: math.min(680, MediaQuery.sizeOf(context).height * .85),
            child: ReaderSettingsSheet(
              bookId: 'desktop-global',
              settings: record.settings,
              bookOverride: false,
              allowBookOverride: false,
              onChanged: (_, _) async {},
            ),
          ),
        ),
      );
    } finally {
      _dialogOpen = false;
      _onExternalImports();
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = IndexedStack(
      index: _currentIndex,
      children: [
        SearchScreen(searchFocusNode: _searchFocus),
        BookshelfScreen(
          key: _bookshelfKey,
          isActive: _currentIndex == 1,
          onGoToDiscover: () {
            setState(() => _currentIndex = 0);
          },
        ),
        HistoryScreen(key: _historyKey),
        if (ReaderPlatform.isMacOS)
          NotesWorkspaceScreen(key: _notesKey, isActive: _currentIndex == 3),
      ],
    );
    if (ReaderPlatform.isMacOS) {
      return Scaffold(
        bottomNavigationBar: TtsPlayerPanel(onClose: () {}),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final extended = constraints.maxWidth >= 1000;
            final railWidth = extended ? 184.0 : 80.0;
            return Row(
              children: [
                SizedBox(
                  width: railWidth,
                  child: NavigationRail(
                    // Only recreate the animated rail at the breakpoint, not
                    // the IndexedStack; shrinking its parent mid-animation
                    // otherwise clips the still-extended destination rows.
                    key: ValueKey(('desktop-navigation', extended)),
                    extended: extended,
                    minWidth: 80,
                    minExtendedWidth: 184,
                    selectedIndex: _currentIndex,
                    onDestinationSelected: _select,
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        children: [
                          Image.asset(
                            'assets/icons/fanqie.png',
                            width: 42,
                            height: 42,
                          ),
                          if (extended) ...[
                            const SizedBox(height: 8),
                            const Text('阅读空间'),
                          ],
                        ],
                      ),
                    ),
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.home_outlined),
                        selectedIcon: Icon(Icons.home_rounded),
                        label: Text('主页'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.collections_bookmark_outlined),
                        selectedIcon: Icon(Icons.collections_bookmark_rounded),
                        label: Text('书架'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.history_outlined),
                        selectedIcon: Icon(Icons.history_rounded),
                        label: Text('历史'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.edit_note_outlined),
                        selectedIcon: Icon(Icons.edit_note),
                        label: Text('笔记'),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      size: Size(
                        math.max(1, constraints.maxWidth - railWidth - 1),
                        constraints.maxHeight,
                      ),
                    ),
                    child: body,
                  ),
                ),
              ],
            );
          },
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TtsPlayerPanel(onClose: () {}),
          NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) {
              _select(index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: '主页',
              ),
              NavigationDestination(
                icon: Icon(Icons.collections_bookmark_outlined),
                selectedIcon: Icon(Icons.collections_bookmark_rounded),
                label: '书架',
              ),
              NavigationDestination(
                icon: Icon(Icons.history_outlined),
                selectedIcon: Icon(Icons.history_rounded),
                label: '历史',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
