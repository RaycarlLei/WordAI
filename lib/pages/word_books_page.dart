import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/word_book_repository.dart';
import '../widgets/wordai_motion.dart';

String bookText(BuildContext context, String en, String hans, String hant) {
  final locale = Localizations.localeOf(context);
  return locale.languageCode != 'zh'
      ? en
      : locale.scriptCode == 'Hant'
          ? hant
          : hans;
}

String bookName(BuildContext context, LocalWordBook book) =>
    switch (book.kind) {
      'default' => bookText(context, 'Default', '默认单词本', '預設單字本'),
      'learned' => bookText(context, 'Learned', '已学会', '已學會'),
      'unfamiliar' => bookText(context, 'Unfamiliar Words', '不熟悉的', '不熟悉的'),
      _ => book.name,
    };

class WordBooksPage extends StatefulWidget {
  const WordBooksPage({super.key, required this.repository});
  final WordBookRepository repository;
  @override
  State<WordBooksPage> createState() => _WordBooksPageState();
}

class _WordBooksPageState extends State<WordBooksPage> {
  List<LocalWordBook> _books = [];
  List<LocalTrashEntry> _trash = [];
  String? _selected;
  bool _busy = true, _showTrash = false;
  String? _error;
  WordBookRepository get repo => widget.repository;
  String t(String en, String hans, String hant) =>
      bookText(context, en, hans, hant);
  @override
  void initState() {
    super.initState();
    _run(() async {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await action();
      final books = await repo.books();
      final trash = await repo.trash();
      if (mounted) {
        setState(() {
          _books = books;
          _trash = trash;
          if (!books.any((b) => b.id == _selected)) _selected = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = t('Could not save or load. Please retry.',
            '无法保存或读取，请重试。', '無法儲存或讀取，請重試。'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editName([LocalWordBook? book]) async {
    final name = await showWordAIGlassDialog<String>(
        context: context,
        builder: (_) => _BookNameDialog(
            initialName: book?.name,
            title: book == null
                ? t('New word book', '新建单词本', '新增單字本')
                : t('Rename', '重命名', '重新命名')));
    if (!mounted || name == null) return;
    await _run(() async {
      if (book == null) {
        _selected = await repo.create(name);
      } else {
        await repo.rename(book.id, name);
      }
    });
  }

  Future<bool> _confirm(String title) async =>
      (await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(title: Text(title), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t('Cancel', '取消', '取消'))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t('Delete', '删除', '刪除'))),
              ]))) ??
      false;

  Future<void> _pickWords(LocalWordBook book) async {
    final List<String> words;
    try {
      words = (await repo.learning.registeredQueries('local')).toList()..sort();
    } catch (_) {
      await _run(
          () => Future<void>.error(StateError('Local storage unavailable')));
      return;
    }
    if (!mounted) return;
    final selected = <String>{};
    final result = await showWordAIGlassDialog<List<String>>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: Text(t('Add words', '添加词条', '新增詞條')),
                    content: SizedBox(
                        width: 480,
                        height: 320,
                        child: words.isEmpty
                            ? Text(t('Import a dictionary first.', '请先导入词库。',
                                '請先匯入詞庫。'))
                            : ListView(children: [
                                for (final word in words)
                                  CheckboxListTile(
                                      title: Text(word),
                                      value: selected.contains(word),
                                      onChanged: (value) => update(() {
                                            if (value == true) {
                                              selected.add(word);
                                            } else {
                                              selected.remove(word);
                                            }
                                          }))
                              ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(t('Cancel', '取消', '取消'))),
                      TextButton(
                          onPressed: () =>
                              Navigator.pop(ctx, selected.toList()),
                          child: Text(t('Add', '添加', '新增')))
                    ])));
    if (result != null && mounted) await _run(() => repo.add(book.id, result));
  }

  Widget _card({required Widget child}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: dark
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                        Color(0xff1b1f28),
                        Color(0xff0e1015),
                        Color(0xff0a0b0f)
                      ],
                    stops: [
                        0,
                        .55,
                        1
                      ])
                : null,
            color: dark ? null : Colors.white,
            border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: .09)
                    : const Color(0xffe5e5ea).withValues(alpha: .3))),
        child: child);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _books.where((b) => b.id == _selected).firstOrNull;
    return Scaffold(
      appBar: AppBar(
          title: Text(_showTrash
              ? t('Recently Deleted', '最近删除', '最近刪除')
              : selected == null
                  ? t('Word books', '单词本', '單字本')
                  : bookName(context, selected)),
          actions: [
            if (!_showTrash && selected == null)
              IconButton(
                  tooltip: t('New word book', '新建单词本', '新增單字本'),
                  onPressed: _busy ? null : _editName,
                  icon: const Icon(Icons.add)),
            IconButton(
                tooltip: t('Recently Deleted', '最近删除', '最近刪除'),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _showTrash = !_showTrash;
                          _selected = null;
                        }),
                icon: const Icon(Icons.delete_outline)),
          ]),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Expanded(child: Text(_error!)),
                        TextButton(
                            onPressed: _busy ? null : () => _run(() async {}),
                            child: Text(t('Retry', '重试', '重試')))
                      ])),
                if (!_showTrash && selected != null)
                  Wrap(spacing: 12, children: [
                    TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _selected = null),
                        child: Text(t('All books', '所有单词本', '所有單字本'))),
                    TextButton(
                        onPressed: _busy ? null : () => _pickWords(selected),
                        child: Text(t('Add words', '添加词条', '新增詞條'))),
                    FilledButton(
                        onPressed: _busy || selected.words.isEmpty
                            ? null
                            : () async {
                                await context.push('/review',
                                    extra: List<String>.of(selected.words));
                                if (mounted) await _run(() async {});
                              },
                        child: Text(t('Review', '复习', '複習'))),
                    if (selected.kind == 'custom')
                      TextButton(
                          onPressed: _busy ? null : () => _editName(selected),
                          child: Text(t('Rename', '重命名', '重新命名'))),
                    if (!selected.permanent)
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  if (await _confirm(t(
                                          'Move this book to Recently Deleted?',
                                          '将单词本移到最近删除？',
                                          '將單字本移到最近刪除？')) &&
                                      mounted) {
                                    await _run(() => repo.delete(selected.id));
                                  }
                                },
                          child: Text(t('Delete', '删除', '刪除'))),
                  ]),
                Expanded(
                    child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: _showTrash
                      ? [
                          if (_trash.isEmpty)
                            Text(t('No recently deleted items.', '没有最近删除的内容。',
                                '沒有最近刪除的內容。')),
                          for (final entry in _trash)
                            _card(
                                child: ListTile(
                                    title: Text(bookName(
                                        context,
                                        LocalWordBook(
                                            entry.bookId,
                                            entry.name,
                                            const {
                                              'default',
                                              'learned',
                                              'unfamiliar'
                                            }.contains(entry.bookId)
                                                ? entry.bookId
                                                : 'custom',
                                            entry.words))),
                                    subtitle: Text(t(
                                        '${entry.words.length} words · kept for 7 days',
                                        '${entry.words.length} 个词 · 保留 7 天',
                                        '${entry.words.length} 個詞 · 保留 7 天')),
                                    trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                              tooltip: t('Restore', '恢复', '還原'),
                                              icon: const Icon(Icons.restore),
                                              onPressed: _busy
                                                  ? null
                                                  : () => _run(() =>
                                                      repo.restore(entry.id))),
                                          IconButton(
                                              tooltip: t('Delete permanently',
                                                  '永久删除', '永久刪除'),
                                              icon: const Icon(
                                                  Icons.delete_forever),
                                              onPressed: _busy
                                                  ? null
                                                  : () async {
                                                      if (await _confirm(t(
                                                              'Permanently delete this item?',
                                                              '永久删除此内容？',
                                                              '永久刪除此內容？')) &&
                                                          mounted) {
                                                        await _run(() => repo
                                                            .permanentlyDelete(
                                                                entry.id));
                                                      }
                                                    }),
                                        ])))
                        ]
                      : selected == null
                          ? [
                              for (final book in _books)
                                _card(
                                    child: ListTile(
                                        title: Text(bookName(context, book)),
                                        subtitle: Text(t(
                                            '${book.words.length} words',
                                            '${book.words.length} 个词',
                                            '${book.words.length} 個詞')),
                                        trailing:
                                            const Icon(Icons.chevron_right),
                                        onTap: _busy
                                            ? null
                                            : () => setState(
                                                () => _selected = book.id)))
                            ]
                          : [
                              if (selected.words.isEmpty)
                                Text(t('This book is empty.', '此单词本为空。',
                                    '此單字本為空。')),
                              for (final word in selected.words)
                                ListTile(
                                    title: Text(word),
                                    trailing: IconButton(
                                        tooltip:
                                            t('Remove word', '移除词条', '移除詞條'),
                                        icon: const Icon(
                                            Icons.remove_circle_outline),
                                        onPressed: _busy
                                            ? null
                                            : () => _run(() => repo
                                                .remove(selected.id, [word]))))
                            ],
                )),
              ]))),
    );
  }
}

class _BookNameDialog extends StatefulWidget {
  const _BookNameDialog({this.initialName, required this.title});
  final String? initialName;
  final String title;
  @override
  State<_BookNameDialog> createState() => _BookNameDialogState();
}

class _BookNameDialogState extends State<_BookNameDialog> {
  late final controller = TextEditingController(text: widget.initialName ?? '');
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 128,
              decoration: InputDecoration(
                  labelText: bookText(context, 'Name', '名称', '名稱'))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(bookText(context, 'Cancel', '取消', '取消'))),
            TextButton(
                onPressed: () {
                  if (controller.text.trim().isNotEmpty) {
                    Navigator.pop(context, controller.text.trim());
                  }
                },
                child: Text(bookText(context, 'Save', '保存', '儲存')))
          ]);
}
