import 'dart:async';

import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../models/reader_theme.dart';
import '../services/reader_font_service.dart';
import '../services/reader_settings_repository.dart';
import '../services/reader_platform.dart';
import 'reader_shortcuts_dialog.dart';
import 'reader_colors_dialog.dart';
import '../services/reader_display_text.dart';
import '../services/external_reader_fonts.dart';
import 'reader_fonts_dialog.dart';

class ReaderSettingsSheet extends StatefulWidget {
  final String bookId;
  final ReaderSettings settings;
  final bool bookOverride;
  final bool allowBookOverride;
  final Future<void> Function(ReaderSettings settings, bool bookOverride)
  onChanged;

  const ReaderSettingsSheet({
    super.key,
    required this.bookId,
    required this.settings,
    required this.bookOverride,
    this.allowBookOverride = true,
    required this.onChanged,
  });

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog();

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  final _controller = TextEditingController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('保存排版预设'),
    content: TextField(
      controller: _controller,
      maxLength: 24,
      autofocus: true,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(hintText: '预设名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: _controller.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('保存'),
      ),
    ],
  );
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet>
    with WidgetsBindingObserver {
  final _repository = ReaderSettingsRepository();
  late ReaderSettings _settings = widget.settings;
  late bool _bookOverride = widget.bookOverride;
  bool _advanced = false;
  bool _busy = false;
  Map<String, ReaderSettings> _presets = {};
  Timer? _themeClock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPresets();
    _loadFonts();
    _themeClock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _settings.themeMode == ReaderThemeMode.scheduled) {
        setState(() {});
      }
    });
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _themeClock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadPresets() async {
    final presets = await _repository.loadPresets();
    if (mounted) setState(() => _presets = presets);
  }

  Future<void> _loadFonts() async {
    try {
      await ExternalReaderFonts().reload();
      if (mounted) setState(() {});
    } catch (_) {
      // Damaged font metadata is preserved; built-in fonts remain usable.
    }
  }

  Future<void> _fontsDialog() async {
    final selected = await _dialog<String>(
      (_) => ReaderFontsDialog(selected: _settings.fontFamily),
    );
    if (!mounted) return;
    setState(() {});
    if (selected != null) {
      await _change(_settings.copyWith(fontFamily: selected));
    } else if (_settings.fontFamily.startsWith('external_') &&
        !ExternalReaderFonts().fonts.any((e) => e.id == _settings.fontFamily)) {
      await _change(_settings.copyWith(fontFamily: 'system'));
    }
  }

  ReaderTheme get _palette => ReaderTheme
      .presets[_settings.effectiveTheme(
        systemDark: MediaQuery.platformBrightnessOf(context) == Brightness.dark,
        now: DateTime.now(),
      )]
      .withColors(
        background: _settings.customBackground,
        text: _settings.customText,
      );

  ThemeData get _themeData => ThemeData(
    brightness: _palette.systemBrightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _palette.textColor,
      brightness: _palette.systemBrightness,
      surface: _palette.backgroundColor,
      onSurface: _palette.textColor,
    ),
    scaffoldBackgroundColor: _palette.backgroundColor,
  );

  Future<T?> _dialog<T>(WidgetBuilder builder) => showDialog<T>(
    context: context,
    builder: (context) => Theme(
      data: _themeData,
      child: Builder(builder: builder),
    ),
  );

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _palette.highlightColor,
        content: Text(
          '设置未保存：$error',
          style: TextStyle(color: _palette.textColor),
        ),
      ),
    );
  }

  Future<void> _change(ReaderSettings next) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ReaderDisplayText.ensureLoaded();
      await ReaderFontService.ensureLoaded(next.fontFamily);
      await _repository.save(
        next,
        bookId: _bookOverride ? widget.bookId : null,
      );
      await widget.onChanged(next, _bookOverride);
      if (mounted) setState(() => _settings = next);
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scope(bool onlyBook) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var value = _settings;
      if (onlyBook) {
        await _repository.save(value, bookId: widget.bookId);
      } else {
        value = (await _repository.load()).settings;
        await ReaderFontService.ensureLoaded(value.fontFamily);
        await _repository.clearBookOverride(widget.bookId);
      }
      await widget.onChanged(value, onlyBook);
      if (mounted) {
        setState(() {
          _settings = value;
          _bookOverride = onlyBook;
        });
      }
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePreset() async {
    final name = await _dialog<String>((context) => const _PresetNameDialog());
    if (!mounted || name == null || name.isEmpty) return;
    if (_presets.containsKey(name)) {
      final replace = await _dialog<bool>(
        (context) => AlertDialog(
          title: Text('替换「$name」？'),
          content: const Text('仅替换此名称的个人排版预设。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    try {
      await _repository.savePreset(name, _settings);
      await _loadPresets();
    } catch (error) {
      _error(error);
    }
  }

  Future<void> _time({required bool night}) async {
    final minute = night
        ? _settings.nightStartMinutes
        : _settings.dayStartMinutes;
    final chosen = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      builder: (context, child) => Theme(data: _themeData, child: child!),
    );
    if (chosen == null || !mounted) return;
    final value = chosen.hour * 60 + chosen.minute;
    if (value ==
        (night ? _settings.dayStartMinutes : _settings.nightStartMinutes)) {
      _error('白天与夜间时间不能相同');
      return;
    }
    await _change(
      night
          ? _settings.copyWith(nightStartMinutes: value)
          : _settings.copyWith(dayStartMinutes: value),
    );
  }

  String _clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );

  Widget _choices<T>(
    Map<T, String> choices,
    T selected,
    void Function(T) change,
  ) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final entry in choices.entries)
        ChoiceChip(
          label: Text(entry.value),
          selected: entry.key == selected,
          onSelected: _busy ? null : (_) => change(entry.key),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final palette = _palette;
    return palette.wrap(
      Builder(
        builder: (context) => Material(
          color: palette.backgroundColor,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '排版与显示',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (_busy)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      IconButton(
                        tooltip: '关闭设置',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: palette.highlightColor,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            ReaderDisplayText.convert(
                              '春风轻拂书页，故事从这里继续。',
                              _settings.displayScript,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _settings.fontSize,
                              height: _settings.lineHeight,
                              letterSpacing: _settings.letterSpacing,
                              color: palette.textColor,
                              fontFamily: ReaderFontService.familyFor(
                                _settings.fontFamily,
                              ),
                              fontFamilyFallback: const [
                                'sans-serif',
                                'Roboto',
                              ],
                            ),
                          ),
                        ),
                        if (widget.allowBookOverride)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('仅此书使用这些设置'),
                            subtitle: const Text('关闭后恢复全局设置，不改变其他书'),
                            value: _bookOverride,
                            onChanged: _busy ? null : _scope,
                          ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('纯净阅读'),
                          subtitle: const Text('暂时隐藏评论与状态信息，关闭后恢复原设置'),
                          value: _settings.pureMode,
                          onChanged: _busy
                              ? null
                              : (value) => _change(
                                  _settings.copyWith(pureMode: value),
                                ),
                        ),
                        _section(
                          '排版预设',
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final entry
                                  in ReaderSettings.presets.entries)
                                ActionChip(
                                  label: Text(entry.key),
                                  onPressed: _busy
                                      ? null
                                      : () => _change(
                                          _settings.typographyFrom(entry.value),
                                        ),
                                ),
                              ActionChip(
                                label: const Text('保存为个人预设'),
                                avatar: const Icon(Icons.add, size: 18),
                                onPressed: _busy ? null : _savePreset,
                              ),
                              for (final entry in _presets.entries)
                                InputChip(
                                  label: Text(entry.key),
                                  onPressed: _busy
                                      ? null
                                      : () => _change(
                                          _settings.typographyFrom(entry.value),
                                        ),
                                  onDeleted: _busy
                                      ? null
                                      : () async {
                                          try {
                                            await _repository.removePreset(
                                              entry.key,
                                            );
                                            await _loadPresets();
                                          } catch (error) {
                                            _error(error);
                                          }
                                        },
                                ),
                            ],
                          ),
                        ),
                        _section(
                          '字号大小',
                          Wrap(
                            spacing: 16,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton(
                                onPressed: _busy || _settings.fontSize <= 13
                                    ? null
                                    : () => _change(
                                        _settings.copyWith(
                                          fontSize: _settings.fontSize - 1,
                                        ),
                                      ),
                                child: const Text('A -'),
                              ),
                              Text('${_settings.fontSize.toInt()}'),
                              OutlinedButton(
                                onPressed: _busy || _settings.fontSize >= 36
                                    ? null
                                    : () => _change(
                                        _settings.copyWith(
                                          fontSize: _settings.fontSize + 1,
                                        ),
                                      ),
                                child: const Text('A +'),
                              ),
                            ],
                          ),
                        ),
                        _section(
                          '正文字体',
                          _choices(
                            {
                              'system': '默认',
                              'kaiti': '楷体',
                              'serif': '宋体',
                              'sans-serif': '黑体',
                              for (final font in ExternalReaderFonts().fonts)
                                font.id: font.name,
                            },
                            _settings.fontFamily,
                            (value) =>
                                _change(_settings.copyWith(fontFamily: value)),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _busy ? null : _fontsDialog,
                          icon: const Icon(Icons.font_download_outlined),
                          label: const Text('导入 / 预览 / 管理 TTF、OTF'),
                        ),
                        _section(
                          '主题切换',
                          _choices(
                            {
                              ReaderThemeMode.manual: '手动',
                              ReaderThemeMode.system: '跟随系统',
                              ReaderThemeMode.scheduled: '定时夜间',
                            },
                            _settings.themeMode,
                            (value) => _change(
                              _settings.copyWith(
                                themeMode: value,
                                clearCustomColors:
                                    value != ReaderThemeMode.manual,
                              ),
                            ),
                          ),
                        ),
                        if (_settings.themeMode == ReaderThemeMode.scheduled)
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _time(night: false),
                                child: Text(
                                  '白天 ${_clock(_settings.dayStartMinutes)}',
                                ),
                              ),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _time(night: true),
                                child: Text(
                                  '夜间 ${_clock(_settings.nightStartMinutes)}',
                                ),
                              ),
                            ],
                          ),
                        _section(
                          '阅读背景（选择后切换为手动）',
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (
                                var index = 0;
                                index < ReaderTheme.presets.length;
                                index++
                              )
                                ChoiceChip(
                                  label: Text(ReaderTheme.presets[index].name),
                                  selected:
                                      _settings.customBackground == null &&
                                      _settings.customText == null &&
                                      _settings.effectiveTheme(
                                            systemDark:
                                                MediaQuery.platformBrightnessOf(
                                                  context,
                                                ) ==
                                                Brightness.dark,
                                            now: DateTime.now(),
                                          ) ==
                                          index,
                                  onSelected: _busy
                                      ? null
                                      : (_) => _change(
                                          _settings.copyWith(
                                            themeIndex: index,
                                            clearCustomColors: true,
                                            themeMode: ReaderThemeMode.manual,
                                            dayThemeIndex: index < 3
                                                ? index
                                                : _settings.dayThemeIndex,
                                            nightThemeIndex: index >= 3
                                                ? index
                                                : _settings.nightThemeIndex,
                                          ),
                                        ),
                                ),
                            ],
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.palette_outlined),
                              label: const Text('自定义配色'),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final colors = await _dialog<(int, int)>(
                                        (_) =>
                                            ReaderColorsDialog(theme: palette),
                                      );
                                      if (colors != null && mounted) {
                                        await _change(
                                          _settings.copyWith(
                                            customBackground: colors.$1,
                                            customText: colors.$2,
                                            themeMode: ReaderThemeMode.manual,
                                          ),
                                        );
                                      }
                                    },
                            ),
                            if (_settings.customBackground != null ||
                                _settings.customText != null)
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _change(
                                        _settings.copyWith(
                                          clearCustomColors: true,
                                        ),
                                      ),
                                child: const Text('恢复预设配色'),
                              ),
                          ],
                        ),
                        if (ReaderPlatform.capabilities.windowBrightness)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('亮度跟随系统'),
                            value: _settings.systemBrightness,
                            onChanged: _busy
                                ? null
                                : (value) => _change(
                                    _settings.copyWith(systemBrightness: value),
                                  ),
                          ),
                        if (ReaderPlatform.capabilities.windowBrightness &&
                            !_settings.systemBrightness)
                          Slider(
                            label: '${(_settings.brightness * 100).round()}%',
                            min: .05,
                            max: 1,
                            value: _settings.brightness,
                            onChanged: _busy
                                ? null
                                : (value) {
                                    final next = _settings.copyWith(
                                      brightness: value,
                                    );
                                    setState(() => _settings = next);
                                    unawaited(
                                      widget.onChanged(next, _bookOverride),
                                    );
                                  },
                            onChangeEnd: _busy
                                ? null
                                : (value) => _change(
                                    _settings.copyWith(brightness: value),
                                  ),
                          ),
                        if (ReaderPlatform.capabilities.windowBrightness)
                          const Text('仅调整阅读窗口，退出阅读后恢复。'),
                        const SizedBox(height: 16),
                        _section(
                          '翻页模式',
                          _choices(
                            {false: '上下滚动', true: '左右翻页'},
                            _settings.pageMode,
                            (value) =>
                                _change(_settings.copyWith(pageMode: value)),
                          ),
                        ),
                        _section(
                          '翻页动画',
                          _choices(
                            {
                              'cover': '覆盖',
                              'simulation': '仿真',
                              'slide': '滑动',
                              'fade': '渐变',
                              'none': '无动画',
                            },
                            _settings.pageAnimation,
                            (value) => _change(
                              _settings.copyWith(
                                pageAnimation: value,
                                pageMode: true,
                              ),
                            ),
                          ),
                        ),
                        if (ReaderPlatform.isMacOS)
                          _section(
                            '桌面阅读栏数',
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _choices(
                                  {
                                    'auto': '自动',
                                    'single': '单栏',
                                    'double': '双栏',
                                  },
                                  _settings.desktopColumns,
                                  (value) => _change(
                                    _settings.copyWith(
                                      desktopColumns: value,
                                      pageMode: value == 'double'
                                          ? true
                                          : _settings.pageMode,
                                    ),
                                  ),
                                ),
                                const Text('双栏用于左右翻页；窗口过窄或文字过大时自动使用单栏。'),
                                const SizedBox(height: 8),
                                _section(
                                  '栏间距',
                                  _choices(
                                    {
                                      16.0: '窄 16',
                                      24.0: '标准 24',
                                      40.0: '宽 40',
                                      64.0: '宽松 64',
                                    },
                                    _settings.columnGap,
                                    (value) => _change(
                                      _settings.copyWith(columnGap: value),
                                    ),
                                  ),
                                ),
                                _section(
                                  '每行目标字数（随字号缩放）',
                                  _choices(
                                    {
                                      0: '充满可用宽度',
                                      24: '24 字',
                                      32: '32 字',
                                      40: '40 字',
                                    },
                                    _settings.lineCharacters,
                                    (value) => _change(
                                      _settings.copyWith(lineCharacters: value),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('高级排版与操作'),
                          initiallyExpanded: _advanced,
                          onExpansionChanged: (value) => _advanced = value,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('中文分页优化'),
                              subtitle: const Text('尽量避免页尾开标点、续页闭标点和段落孤行'),
                              value: _settings.smartTypography,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(
                                        smartTypography: value,
                                      ),
                                    ),
                            ),
                            _section(
                              '简繁显示（不改写原文）',
                              _choices(
                                {
                                  'original': '原文',
                                  'simplified': '简体',
                                  'traditional': '繁体',
                                },
                                _settings.displayScript,
                                (value) => _change(
                                  _settings.copyWith(displayScript: value),
                                ),
                              ),
                            ),
                            const Text(
                              '简繁为离线逐字显示转换，复制、搜索、批注和听书仍使用原文；多义字可能需要人工判断。',
                            ),
                            if (ReaderPlatform.isMacOS)
                              _section(
                                '动画速度',
                                _choices(
                                  {.7: '舒缓', 1.0: '标准', 1.4: '快捷'},
                                  _settings.animationSpeed,
                                  (value) => _change(
                                    _settings.copyWith(animationSpeed: value),
                                  ),
                                ),
                              ),
                            SwitchListTile(
                              title: const Text('正文点击翻页'),
                              subtitle: const Text('关闭后单击只打开菜单，键盘与滚轮仍可翻页'),
                              contentPadding: EdgeInsets.zero,
                              value: _settings.tapToTurn,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(tapToTurn: value),
                                    ),
                            ),
                            if (ReaderPlatform.isMacOS)
                              TextButton.icon(
                                onPressed: () => _dialog(
                                  (_) => const ReaderShortcutsDialog(),
                                ),
                                icon: const Icon(Icons.keyboard_outlined),
                                label: const Text('自定义阅读快捷键'),
                              ),
                            _section(
                              '行间距',
                              _choices(
                                {1.5: '紧凑 1.5', 1.8: '适中 1.8', 2.2: '宽松 2.2'},
                                _settings.lineHeight,
                                (value) => _change(
                                  _settings.copyWith(lineHeight: value),
                                ),
                              ),
                            ),
                            _section(
                              '字间距',
                              _choices(
                                {0.0: '紧凑 0.0', .5: '适中 0.5', 1.2: '宽松 1.2'},
                                _settings.letterSpacing,
                                (value) => _change(
                                  _settings.copyWith(letterSpacing: value),
                                ),
                              ),
                            ),
                            _section(
                              '段间距',
                              _choices(
                                {8.0: '小段距', 14.0: '中段距', 20.0: '大段距'},
                                _settings.paragraphSpacing,
                                (value) => _change(
                                  _settings.copyWith(paragraphSpacing: value),
                                ),
                              ),
                            ),
                            _section(
                              '页边距',
                              _choices(
                                {14.0: '窄边距', 20.0: '中边距', 28.0: '宽边距'},
                                _settings.horizontalPadding,
                                (value) => _change(
                                  _settings.copyWith(horizontalPadding: value),
                                ),
                              ),
                            ),
                            _section(
                              '点击热区',
                              _choices(
                                {
                                  'balanced': '左右均衡',
                                  'right_hand': '右手单手',
                                  'left_hand': '左手单手',
                                },
                                _settings.tapLayout,
                                (value) => _change(
                                  _settings.copyWith(tapLayout: value),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                _settings.tapLayout == 'left_hand'
                                    ? '左侧 45%：下一页 · 中间：菜单 · 右侧 18%：上一页'
                                    : _settings.tapLayout == 'right_hand'
                                    ? '左侧 18%：上一页 · 中间：菜单 · 右侧 45%：下一页'
                                    : '左侧 28%：上一页 · 中间：菜单 · 右侧 28%：下一页',
                              ),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('显示顶部章节信息'),
                              value: _settings.showHeader,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(showHeader: value),
                                    ),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('显示时间、电量与进度'),
                              value: _settings.showStatus,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(showStatus: value),
                                    ),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('阅读时屏幕常亮'),
                              value: _settings.keepScreenOn,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(keepScreenOn: value),
                                    ),
                            ),
                            if (ReaderPlatform.capabilities.haptics)
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('翻页触感反馈'),
                                value: _settings.haptics,
                                onChanged: _busy
                                    ? null
                                    : (value) => _change(
                                        _settings.copyWith(haptics: value),
                                      ),
                              ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('休息提醒'),
                              subtitle: const Text('只在前台阅读时计时，不弹窗打断'),
                              value: _settings.restReminder,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(restReminder: value),
                                    ),
                            ),
                            if (_settings.restReminder)
                              _choices<int>(
                                {20: '20 分钟', 30: '30 分钟', 60: '60 分钟'},
                                _settings.restMinutes,
                                (value) => _change(
                                  _settings.copyWith(restMinutes: value),
                                ),
                              ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('首行缩进 (2字符)'),
                              value: _settings.indent,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(indent: value),
                                    ),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('段评气泡'),
                              value: _settings.commentBubbles,
                              onChanged: _busy
                                  ? null
                                  : (value) => _change(
                                      _settings.copyWith(commentBubbles: value),
                                    ),
                            ),
                            if (ReaderPlatform.capabilities.volumeKeys)
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('音量键翻页'),
                                subtitle: const Text('听书时保留音量键调节音量'),
                                value: _settings.volumeKeys,
                                onChanged: _busy
                                    ? null
                                    : (value) => _change(
                                        _settings.copyWith(volumeKeys: value),
                                      ),
                              ),
                          ],
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.restore),
                          label: const Text('恢复默认设置'),
                          onPressed: _busy
                              ? null
                              : () async {
                                  final confirmed = await _dialog<bool>(
                                    (context) => AlertDialog(
                                      title: const Text('恢复默认设置？'),
                                      content: Text(
                                        _bookOverride
                                            ? '仅重置此书的阅读设置。'
                                            : '重置全局阅读设置，不影响单书设置和个人预设。',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('取消'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('恢复默认'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed == true) {
                                    await _change(const ReaderSettings());
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
