import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_selector/file_selector.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'flutter_flow/flutter_flow_theme.dart';
import 'flutter_flow/internationalization.dart';
import 'pages/flash_cards/flash_cards_widget.dart';
import 'services/learning_repository.dart';
import 'services/dictionary_import.dart';
import 'services/backup_files.dart';
import 'services/learning_backup.dart';
import 'widgets/learning_backup_dialog.dart';
import 'widgets/reicon.dart';
import 'widgets/wordai_motion.dart';
import 'sample_words.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux || Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await FlutterFlowTheme.initialize();
  runApp(const CommunityApp());
}

class CommunityApp extends StatefulWidget {
  const CommunityApp({
    super.key,
    @visibleForTesting this.homeRepository,
    @visibleForTesting this.selectDictionary,
    @visibleForTesting this.backupFiles,
  });
  final LearningRepository? homeRepository;
  final Future<XFile?> Function()? selectDictionary;
  final BackupFiles? backupFiles;
  @override
  State<CommunityApp> createState() => _CommunityAppState();
}

class _CommunityAppState extends State<CommunityApp> {
  Locale _locale = const Locale('en');
  late final GoRouter _router = GoRouter(routes: [
    GoRoute(
        path: '/',
        builder: (_, __) => _Home(
            repository: widget.homeRepository ?? LearningRepository.instance,
            selectDictionary: widget.selectDictionary,
            backupFiles: widget.backupFiles,
            onLocale: (locale) => setState(() => _locale = locale))),
    GoRoute(
        path: '/review',
        builder: (_, state) => FlashCardsWidget(
            initialWords: (state.extra as List<String>?) ?? const [])),
  ]);
  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'WordAI Community',
        routerConfig: _router,
        locale: _locale,
        supportedLocales: const [
          Locale('en'),
          Locale('zh'),
          Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
        ],
        localizationsDelegates: const [
          FFLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        theme: ThemeData(
            colorScheme:
                ColorScheme.fromSeed(seedColor: const Color(0xff448aff)),
            useMaterial3: true),
        darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff448aff),
                brightness: Brightness.dark),
            useMaterial3: true),
      );
}

class _Home extends StatefulWidget {
  const _Home(
      {required this.onLocale,
      required this.repository,
      this.backupFiles,
      this.selectDictionary});
  final ValueChanged<Locale> onLocale;
  final LearningRepository repository;
  final Future<XFile?> Function()? selectDictionary;
  final BackupFiles? backupFiles;
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  LearningRepository get _repo => widget.repository;
  late final BackupFiles _backupFiles =
      widget.backupFiles ?? PlatformBackupFiles();
  List<String> _words = [];
  bool _busy = true;
  bool _backupOpen = false;
  String? _importMessage;
  String? _loadError;
  int _pending = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  String t(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  Future<void> _load() async {
    if (mounted) setState(() => _busy = true);
    try {
      // A restored vocabulary is authoritative. Seed only an empty profile,
      // so retries and later launches do not add words to a restored backup.
      await _repo.seedEmptyProfile('local', sampleWords());
      final words = (await _repo.registeredQueries('local')).toList()..sort();
      final pending = await _repo.reviewableWordCount('local');
      if (mounted) {
        setState(() {
          _words = words;
          _pending = pending;
          _busy = false;
          _loadError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _loadError = 'Local storage is unavailable. Please retry.';
        });
      }
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _importMessage = null;
    });
    var imported = 0;
    try {
      const type = XTypeGroup(
          label: 'WordAI dictionary',
          extensions: ['json'],
          uniformTypeIdentifiers: ['public.json']);
      final file = await (widget.selectDictionary?.call() ??
          openFile(acceptedTypeGroups: [type]));
      if (file == null) return;
      imported = await importDictionary(file.openRead(),
          repository: _repo,
          uid: 'local',
          onImported: (count) => imported = count);
      if (mounted) {
        setState(() => _importMessage =
            'Imported $imported ${imported == 1 ? 'entry' : 'entries'}.');
      }
    } on DictionaryImportException catch (error) {
      if (mounted) {
        setState(() =>
            _importMessage = '${error.message} No entries were imported.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _importMessage =
            'Import stopped after $imported ${imported == 1 ? 'entry' : 'entries'}. Check the file and available storage; existing progress is retained.');
      }
    } finally {
      await _load();
    }
  }

  Future<void> _backup() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _backupOpen = true;
    });
    await showWordAIGlassDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LearningBackupDialog(
        service: LearningBackupService(_repo),
        files: _backupFiles,
      ),
    );
    if (mounted) {
      setState(() => _backupOpen = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('WordAI Community'), actions: [
          PopupMenuButton<Locale>(
              enabled: !_busy,
              tooltip: t('Language', '语言'),
              icon: const Reicon(ReiconGlyph.globe),
              onSelected: widget.onLocale,
              itemBuilder: (_) => const [
                    PopupMenuItem(value: Locale('en'), child: Text('English')),
                    PopupMenuItem(value: Locale('zh'), child: Text('简体中文')),
                    PopupMenuItem(
                        value: Locale.fromSubtags(
                            languageCode: 'zh', scriptCode: 'Hant'),
                        child: Text('繁體中文'))
                  ])
        ]),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: CustomScrollView(slivers: [
                      SliverToBoxAdapter(
                          child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        t('Learn locally. Keep your progress.',
                                            '离线学习，进度保存在本机。'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall),
                                    const SizedBox(height: 8),
                                    Text(t(
                                        '${_words.length} words · $_pending left to learn',
                                        '${_words.length} 个词 · $_pending 个待学习')),
                                    const SizedBox(height: 16),
                                    Wrap(spacing: 12, runSpacing: 8, children: [
                                      FilledButton.icon(
                                          onPressed: _busy || _words.isEmpty
                                              ? null
                                              : () async {
                                                  await context.push('/review',
                                                      extra: _words);
                                                  await _load();
                                                },
                                          icon: const Reicon(ReiconGlyph.book),
                                          label: Text(
                                              t('Start flashcards', '开始闪卡'))),
                                      OutlinedButton.icon(
                                          onPressed: _busy ? null : _import,
                                          icon: const Reicon(
                                              ReiconGlyph.folderOpen),
                                          label: Text(
                                              t('Import dictionary', '导入词库'))),
                                      OutlinedButton.icon(
                                          onPressed: _busy ? null : _backup,
                                          icon:
                                              const Reicon(ReiconGlyph.archive),
                                          label: Text(
                                              t('Learning backup', '学习备份'))),
                                      IconButton(
                                          onPressed: _busy ? null : _load,
                                          tooltip: t('Retry', '重试'),
                                          icon: const Reicon(
                                              ReiconGlyph.refresh)),
                                    ]),
                                    for (final message in [
                                      _importMessage,
                                      _loadError
                                    ].whereType<String>())
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(top: 12),
                                          child: Text(message)),
                                  ]))),
                      if (_busy && !_backupOpen)
                        const SliverToBoxAdapter(
                            child: LinearProgressIndicator()),
                      SliverList.builder(
                          itemCount: _words.length,
                          itemBuilder: (_, i) => ListTile(
                              leading: const Reicon(ReiconGlyph.book),
                              title: Text(_words[i]),
                              trailing: const Reicon(ReiconGlyph.chevronRight),
                              onTap: _busy
                                  ? null
                                  : () async {
                                      await context
                                          .push('/review', extra: [_words[i]]);
                                      await _load();
                                    })),
                    ])))),
      );
}
