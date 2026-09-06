import 'dart:convert';
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
import 'services/wordai_dossier.dart';
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
  const CommunityApp({super.key});
  @override
  State<CommunityApp> createState() => _CommunityAppState();
}

class _CommunityAppState extends State<CommunityApp> {
  Locale _locale = const Locale('en');
  late final GoRouter _router = GoRouter(routes: [
    GoRoute(
        path: '/',
        builder: (_, __) =>
            _Home(onLocale: (locale) => setState(() => _locale = locale))),
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
  const _Home({required this.onLocale});
  final ValueChanged<Locale> onLocale;
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _repo = LearningRepository.instance;
  List<String> _words = [];
  bool _busy = true;
  String? _message;
  int _pending = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  String t(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  Future<void> _load() async {
    try {
      for (final d in sampleWords()) {
        await _repo.registerDossier('local', d);
      }
      final words = (await _repo.registeredQueries('local')).toList()..sort();
      final pending = await _repo.reviewableWordCount('local');
      if (mounted) {
        setState(() {
          _words = words;
          _pending = pending;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Local storage is unavailable. Please retry.';
        });
      }
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    var imported = 0;
    try {
      const type = XTypeGroup(
          label: 'WordAI dictionary',
          extensions: ['json'],
          uniformTypeIdentifiers: ['public.json']);
      final file = await openFile(acceptedTypeGroups: [type]);
      if (file == null) return;
      if (await file.length() > 10 * 1024 * 1024) {
        throw const FormatException('File exceeds 10 MB.');
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List || decoded.length > 20000) {
        throw const FormatException('Expected up to 20,000 S6 entries.');
      }
      final entries = decoded.map((row) {
        if (row is! Map<String, dynamic> || row['query'] is! String) {
          throw const FormatException('Invalid dictionary entry.');
        }
        return WordAiDossier.fromJson(row, expectedQuery: row['query']);
      }).toList();
      for (final entry in entries) {
        await _repo.registerDossier('local', entry);
        imported++;
      }
      if (mounted) setState(() => _message = 'Imported $imported entries.');
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Import stopped after $imported entries. Check the S6 format and available storage; existing progress is retained.');
      }
    } finally {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('WordAI Community'), actions: [
          PopupMenuButton<Locale>(
              icon: const Icon(Icons.language),
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
                    child: Column(children: [
                      Padding(
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
                                      icon: const Icon(Icons.school),
                                      label:
                                          Text(t('Start flashcards', '开始闪卡'))),
                                  OutlinedButton.icon(
                                      onPressed: _busy ? null : _import,
                                      icon: const Icon(Icons.file_open),
                                      label:
                                          Text(t('Import dictionary', '导入词库'))),
                                  IconButton(
                                      onPressed: _busy ? null : _load,
                                      tooltip: t('Retry', '重试'),
                                      icon: const Icon(Icons.refresh)),
                                ]),
                                if (_message != null)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(_message!)),
                              ])),
                      if (_busy) const LinearProgressIndicator(),
                      Expanded(
                          child: ListView.builder(
                              itemCount: _words.length,
                              itemBuilder: (_, i) => ListTile(
                                  leading: const Icon(Icons.menu_book_outlined),
                                  title: Text(_words[i]),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: _busy
                                      ? null
                                      : () async {
                                          await context.push('/review',
                                              extra: [_words[i]]);
                                          await _load();
                                        }))),
                    ])))),
      );
}
