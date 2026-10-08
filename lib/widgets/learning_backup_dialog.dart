import 'package:flutter/material.dart';

import '../services/backup_files.dart';
import '../services/learning_backup.dart';
import 'reicon.dart';

class LearningBackupDialog extends StatefulWidget {
  const LearningBackupDialog(
      {super.key, required this.service, required this.files});

  final LearningBackupService service;
  final BackupFiles files;

  @override
  State<LearningBackupDialog> createState() => _LearningBackupDialogState();
}

class _LearningBackupDialogState extends State<LearningBackupDialog> {
  bool _busy = false;
  LearningBackup? _candidate;
  String? _message;
  bool _failed = false;

  String t(String en, String hans, String hant) {
    final locale = Localizations.localeOf(context);
    return locale.languageCode != 'zh'
        ? en
        : locale.scriptCode == 'Hant'
            ? hant
            : hans;
  }

  void _start() => setState(() {
        _busy = true;
        _message = null;
        _failed = false;
      });

  void _finish(String message, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _failed = failed;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    _start();
    try {
      final backup = await widget.service.capture();
      if (!mounted) return;
      final saved = await widget.files.save(backup.toBytes(),
          suggestedName: 'wordai-learning-${backup.createdAtMs}.json');
      if (!mounted) return;
      _finish(saved
          ? t('Backup saved.', '备份已保存。', '備份已儲存。')
          : t('Save cancelled.', '已取消保存。', '已取消儲存。'));
    } catch (_) {
      if (!mounted) return;
      _finish(
          t('The backup could not be saved. A partial file may remain; choose a new file and try again.',
              '未能保存备份，所选位置可能留有不完整文件。请选择新文件重试。', '無法儲存備份，所選位置可能留有不完整檔案。請選擇新檔案重試。'),
          failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select() async {
    if (_busy) return;
    _start();
    try {
      final file = await widget.files.select();
      if (!mounted || file == null) return;
      final backup = await readLearningBackup(file.openRead());
      if (mounted) setState(() => _candidate = backup);
    } catch (_) {
      if (!mounted) return;
      _finish(
          t(
              'The file could not be opened as a complete WordAI learning backup (up to 32 MiB). Local data has not changed.',
              '无法将此文件读取为完整的 WordAI 学习备份（最大 32 MiB）。本机数据未更改。',
              '無法將此檔案讀取為完整的 WordAI 學習備份（最大 32 MiB）。本機資料未變更。'),
          failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final backup = _candidate;
    if (_busy || backup == null) return;
    _start();
    try {
      await widget.service.restore(backup);
      if (!mounted) return;
      setState(() => _candidate = null);
      _finish(t('Learning data restored. Start a new round to continue.',
          '学习数据已恢复，开始新一轮即可继续。', '學習資料已還原，開始新一輪即可繼續。'));
    } catch (_) {
      if (!mounted) return;
      _finish(
          t('Restore could not be confirmed. Reopen the app and check your learning data before retrying.',
              '未能确认恢复完成。请重新打开应用，检查学习数据后再重试。', '無法確認還原完成。請重新開啟應用程式，檢查學習資料後再重試。'),
          failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _date(LearningBackup backup) {
    final date =
        DateTime.fromMillisecondsSinceEpoch(backup.createdAtMs).toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(date)} · ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  String _count(int count, String unit) =>
      '$count $unit${count == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final backup = _candidate;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        // A selected file starts a new reading position, even if the action
        // view was scrolled to reach its buttons at a large text size.
        key: ValueKey(backup == null ? 'backup-actions' : 'backup-preview'),
        scrollable: true,
        constraints: const BoxConstraints(maxWidth: 540),
        title: Text(backup == null
            ? t('Learning backup', '学习备份', '學習備份')
            : t('Review backup', '检查备份', '檢查備份')),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (backup == null) ...[
              Text(t(
                  'Save your vocabulary, progress, word books and recently deleted items to a file you choose.',
                  '将词汇、学习进度、单词本和最近删除保存到你选择的文件。',
                  '將詞彙、學習進度、單字本和最近刪除儲存到你選擇的檔案。')),
              const SizedBox(height: 12),
              Text(
                  t('Backups are readable JSON. Keep them somewhere private.',
                      '备份为可读的 JSON 文件，请存放在私密位置。', '備份為可讀的 JSON 檔案，請存放在私密位置。'),
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 20),
              Wrap(spacing: 12, runSpacing: 12, children: [
                FilledButton.icon(
                  onPressed: _busy || !widget.files.canSave ? null : _save,
                  icon: const Reicon(ReiconGlyph.download),
                  label: Text(t('Save backup', '保存备份', '儲存備份')),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _select,
                  icon: const Reicon(ReiconGlyph.upload),
                  label: Text(t('Restore from file', '从文件恢复', '從檔案還原')),
                ),
              ]),
              if (!widget.files.canSave) ...[
                const SizedBox(height: 12),
                Text(t('Saving is unavailable on this platform.',
                    '此平台暂不支持保存备份。', '此平台暫不支援儲存備份。')),
              ],
            ] else ...[
              Text(_date(backup)),
              Text(t(
                  '${backup.bookCount} books · ${backup.trashCount} recently deleted',
                  '${backup.bookCount} 个单词本 · ${backup.trashCount} 项最近删除',
                  '${backup.bookCount} 個單字本 · ${backup.trashCount} 項最近刪除')),
              if (backup.bookCount == 0)
                Text(t('Legacy backup: system books will be initialized.',
                    '旧版备份：将初始化系统单词本。', '舊版備份：將初始化系統單字本。')),
              const SizedBox(height: 12),
              Text(t(
                  '${_count(backup.progressCount, 'meaning')} · ${_count(backup.attemptCount, 'answer')} · ${_count(backup.sessionCount, 'session')}',
                  '${backup.progressCount} 个词义 · ${backup.attemptCount} 次答题 · ${backup.sessionCount} 轮学习',
                  '${backup.progressCount} 個詞義 · ${backup.attemptCount} 次答題 · ${backup.sessionCount} 輪學習')),
              const SizedBox(height: 16),
              Text(t(
                  'This replaces all local vocabulary, progress, word books, recently deleted items and review history. Save your current data first if you want to keep it.',
                  '这会替换本机全部词汇、学习进度、单词本、最近删除和答题历史。如果需要保留当前数据，请先保存备份。',
                  '這會替換本機全部詞彙、學習進度、單字本、最近刪除和答題歷史。如果需要保留目前資料，請先儲存備份。')),
              const SizedBox(height: 12),
              Text(t(
                  'Unfinished rounds will be closed. Your earned progress and answers are kept; questions are prepared again next round.',
                  '未完成的学习轮次将结束，已取得的进度和答题记录会保留，题目将在下一轮重新准备。',
                  '未完成的學習輪次將結束，已取得的進度和答題紀錄會保留，題目將在下一輪重新準備。')),
            ],
            if (_busy) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(
                  semanticsLabel:
                      t('Working with your backup', '正在处理备份', '正在處理備份')),
            ],
            if (_message != null) ...[
              const SizedBox(height: 16),
              Semantics(
                  liveRegion: true,
                  child: Text(_message!,
                      style: TextStyle(
                          color: _failed
                              ? Theme.of(context).colorScheme.error
                              : null))),
            ],
          ],
        ),
        actions: [
          if (backup == null)
            TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(t('Close', '关闭', '關閉')))
          else ...[
            TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _candidate = null;
                          _message = null;
                        }),
                child: Text(t('Cancel', '取消', '取消'))),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              ),
              onPressed: _busy ? null : _restore,
              child: Text(
                  t('Replace local learning data', '替换本机学习数据', '替換本機學習資料'),
                  textAlign: TextAlign.center),
            ),
          ],
        ],
      ),
    );
  }
}
