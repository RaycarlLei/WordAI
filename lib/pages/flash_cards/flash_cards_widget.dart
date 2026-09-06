import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/services/learning_repository.dart';
import '/services/review_preparation.dart';
import '/services/review_pronunciation.dart';
import '/widgets/review_loading_view.dart';

class FlashCardsWidget extends StatefulWidget {
  const FlashCardsWidget({
    super.key,
    @visibleForTesting this.repository,
    @visibleForTesting this.testUid,
    this.initialWords,
    @visibleForTesting this.dossierLoader,
    @visibleForTesting this.activeUid,
    @visibleForTesting this.pronunciation,
    @visibleForTesting this.preparationBudget = const Duration(seconds: 35),
  });

  final LearningRepository? repository;
  final String? testUid;
  final List<String>? initialWords;
  final ReviewDossierLoader? dossierLoader;
  final String Function()? activeUid;
  final ReviewPronunciation? pronunciation;
  final Duration preparationBudget;

  @override
  State<FlashCardsWidget> createState() => _FlashCardsWidgetState();
}

class _FlashCardsWidgetState extends State<FlashCardsWidget>
    with WidgetsBindingObserver {
  static const _emptyDeviceCloudBudget = Duration(milliseconds: 800);
  static const _correctAnswerHoldDuration = Duration(milliseconds: 1000);

  late final LearningRepository _repository;
  late final ReviewPronunciation _pronunciation;
  int _audioGeneration = 0;
  bool _audioForeground = true;
  ReviewSessionState? _session;
  ReviewQuestion? _question;
  ReviewAnswerResult? _answer;
  int? _selectedIndex;
  bool _loading = true;
  bool _submitting = false;
  bool _completing = false;
  bool _exitDialogOpen = false;
  String? _error;
  String _preparationDetail = '';
  DateTime? _questionStartedAt;
  DateTime? _activeSegmentStarted;
  int _activeSegmentMs = 0;
  Timer? _correctAdvanceTimer;
  ReviewPreparationRun? _preparationRun;
  bool _advancing = false;
  bool _needsMoreContent = false;
  late final String _reviewUid;

  String get _uid => _reviewUid;
  bool get _accountIsCurrent =>
      (widget.activeUid?.call() ?? widget.testUid ?? 'local') == _uid;

  // Existing repository-only test fixtures have no word-book route. Real
  // review routes always keep their selected collection, including an empty one.
  List<String>? get _reviewScope =>
      widget.testUid != null && widget.initialWords?.isEmpty == true
          ? null
          : _wordsFromRoute();

  Future<ReviewSessionState?> _resumeSession() {
    final scope = _reviewScope;
    return scope == null
        ? _repository.resumeActiveSession(_uid)
        : _repository.resumeScopedSession(_uid, scope);
  }

  @override
  void initState() {
    super.initState();
    _reviewUid = widget.testUid ?? 'local';
    _repository = widget.repository ?? LearningRepository.instance;
    _pronunciation = widget.pronunciation ?? ReviewPronunciation.cached();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _audioForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _audioGeneration++;
    _pronunciation.dispose();
    _preparationRun?.cancel();
    _cancelCorrectAdvance();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _audioForeground = true;
      if (!_accountIsCurrent) {
        unawaited(_requestExit());
        return;
      }
      if (!_loading) _activeSegmentStarted ??= DateTime.now();
      _schedulePronunciation();
      WidgetsBinding.instance.ensureVisualUpdate();
      if (_answer?.correct == true && !_exitDialogOpen && !_completing) {
        _scheduleCorrectAdvance(_question?.target.targetId);
      }
    } else {
      _audioForeground = false;
      _stopPronunciation();
      _cancelCorrectAdvance();
      _pauseActiveTimer();
    }
  }

  void _stopPronunciation() {
    _audioGeneration++;
    _pronunciation.stop();
  }

  void _schedulePronunciation() {
    final question = _question;
    final session = _session;
    if (question == null ||
        session == null ||
        _loading ||
        _error != null ||
        _answer != null ||
        _completing ||
        _exitDialogOpen ||
        !_audioForeground ||
        !_accountIsCurrent) {
      return;
    }
    final generation = _audioGeneration;
    final key =
        '${session.id}:${question.target.targetId}:${question.target.stage}';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _audioGeneration ||
          !_audioForeground ||
          !_accountIsCurrent ||
          !identical(question, _question) ||
          _loading ||
          _error != null ||
          _answer != null ||
          _exitDialogOpen ||
          _completing) {
        return;
      }
      _pronunciation.show(key, question.target.word);
    });
  }

  void _cancelCorrectAdvance() {
    _correctAdvanceTimer?.cancel();
    _correctAdvanceTimer = null;
  }

  void _scheduleCorrectAdvance(String? targetId) {
    if (targetId == null) return;
    _cancelCorrectAdvance();
    _correctAdvanceTimer = Timer(_correctAnswerHoldDuration, () {
      _correctAdvanceTimer = null;
      if (!mounted ||
          _answer?.correct != true ||
          _question?.target.targetId != targetId ||
          _exitDialogOpen ||
          _completing) {
        return;
      }
      unawaited(_advanceToNext(showPreparation: false));
    });
  }

  void _pauseActiveTimer() {
    final started = _activeSegmentStarted;
    if (started != null) {
      _activeSegmentMs += DateTime.now().difference(started).inMilliseconds;
      _activeSegmentStarted = null;
    }
  }

  int get _activeMs {
    final live = _activeSegmentStarted == null
        ? 0
        : DateTime.now().difference(_activeSegmentStarted!).inMilliseconds;
    return (_session?.activeMs ?? 0) + _activeSegmentMs + live;
  }

  void _setPreparationDetail(String en, String hans, String hant) {
    if (!mounted) return;
    final detail = _t(en, hans, hant);
    if (_preparationDetail == detail) return;
    setState(() => _preparationDetail = detail);
  }

  List<String> _wordsFromRoute() => widget.initialWords ?? const [];

  bool _ownsRun(ReviewPreparationRun run) =>
      mounted && identical(_preparationRun, run) && !run.isCancelled;

  void _checkRun(ReviewPreparationRun run) {
    if (!_ownsRun(run) || !_accountIsCurrent) {
      run.cancel();
    }
    run.check();
  }

  Future<void> _syncSafely() async {
    try {
      await _repository.syncFromCloud(_uid);
    } catch (error, stack) {
      _logDeveloperError('review.backgroundSync', error, stack);
    }
  }

  Future<void> _initialize() async {
    if (!mounted) return;
    _cancelCorrectAdvance();
    _preparationRun?.cancel();
    final run = ReviewPreparationRun(budget: widget.preparationBudget);
    _preparationRun = run;
    if (!_accountIsCurrent) {
      run.cancel();
      context.pop();
      return;
    }
    setState(() {
      _loading = true;
      _question = null;
      _answer = null;
      _error = null;
      _needsMoreContent = false;
      _preparationDetail =
          _t('Restoring learning progress…', '正在恢复学习进度…', '正在恢復學習進度…');
    });
    _stopPronunciation();
    // Attach an error handler immediately; a background failure must not
    // escape before a later await or take down local review.
    final languageCode = FFLocalizations.of(context).languageCode;
    final cloudSync = _syncSafely();
    try {
      var session = await run.wait(_resumeSession());
      var restoredSession = session != null;
      _checkRun(run);
      if (session == null &&
          await run.wait(_repository.reviewableWordCount(_uid,
                  queries: _reviewScope)) ==
              0) {
        _setPreparationDetail(
            'Checking briefly for progress from another device…',
            '正在快速检查其他设备的进度…',
            '正在快速檢查其他裝置的進度…');
        try {
          await run.wait(cloudSync, timeout: _emptyDeviceCloudBudget);
        } on TimeoutException {
          // Background sync never gates an otherwise usable local round.
        }
        _checkRun(run);
        session = await run.wait(_resumeSession());
        restoredSession = session != null;
      }
      if (session == null) {
        _checkRun(run);
        await _seedAvailableWords(_wordsFromRoute(), run);
        _checkRun(run);
        _setPreparationDetail('Randomly selecting up to 20 words…',
            '正在随机抽取最多 20 个词…', '正在隨機抽取最多 20 個詞…');
        session = await run.wait(_repository.createSession(_uid,
            languageCode: languageCode, queries: _reviewScope));
      }
      _checkRun(run);
      _session = session;
      _activeSegmentMs = 0;
      _activeSegmentStarted = null;
      if (session != null) {
        _setPreparationDetail('Building trustworthy choices locally…',
            '正在本地生成可信的选项…', '正在本機產生可信的選項…');
        await _loadNextQuestion(run);
      }
      // A saved round may contain only removed, learned or damaged targets.
      // Retiring it must not hide other words that can form a fresh round.
      if (restoredSession && _session == null && _question == null) {
        await _seedAvailableWords(_wordsFromRoute(), run);
        _checkRun(run);
        _session = await run.wait(_repository.createSession(_uid,
            languageCode: languageCode, queries: _reviewScope));
        if (_session != null) await _loadNextQuestion(run);
      }
      if (_question == null && !_completing) await _refreshEmptyState(run);
      if (_ownsRun(run)) setState(() => _loading = false);
      // Batch registration writes a durable outbox, not hundreds of parallel
      // Firestore requests. Flush it after the UI becomes ready.
      unawaited(cloudSync.then((_) {
        if (_ownsRun(run) && _accountIsCurrent) {
          return _syncSafely();
        }
      }));
    } on ReviewPreparationCancelled {
      // Page was closed, account changed, or a newer run superseded this one.
      if (mounted && !_accountIsCurrent) context.pop();
    } catch (error, stackTrace) {
      if (!_ownsRun(run)) return;
      run.cancel();
      _logDeveloperError('review.initialize', error, stackTrace);
      setState(() {
        _loading = false;
        _error = _t(
          'Preparation took too long or could not finish. Your saved progress is safe. Please try again.',
          '准备暂未完成，已保存的进度不会丢失。请重试。',
          '準備暫未完成，已儲存的進度不會遺失。請重試。',
        );
      });
    }
  }

  Future<void> _refreshEmptyState(ReviewPreparationRun run) async {
    final pending = await run
        .wait(_repository.reviewableWordCount(_uid, queries: _reviewScope));
    final registered = await run.wait(_repository.registeredQueries(_uid));
    _checkRun(run);
    final missing = _wordsFromRoute().any((word) {
      final normalized = word.trim().toLowerCase();
      return normalized.isNotEmpty && !registered.contains(normalized);
    });
    // A null question only means preparation failed. Only persisted progress
    // covering every requested word can establish that learning is complete.
    _needsMoreContent = pending > 0 || missing;
  }

  Future<void> _seedAvailableWords(
      List<String> words, ReviewPreparationRun run) async {
    final preparer = ReviewWordPreparer(
      repository: _repository,
      onFailure: (stage, error, stack) =>
          _logDeveloperError('review.prepare.$stage', error, stack),
      load: widget.dossierLoader ?? (_, __) => const Stream.empty(),
    );
    await preparer.prepare(
      uid: _uid,
      words: words,
      limitToWords: _reviewScope != null,
      languageCode: FFLocalizations.of(context).languageCode,
      run: run,
      onProgress: (
          {required cloud, required checked, required total, required ready}) {
        _checkRun(run);
        if (cloud) {
          _setPreparationDetail(
              'Completing missing content online · $checked/$total',
              '正在联网补全缺失内容 · $checked/$total',
              '正在連線補全缺失內容 · $checked/$total');
        } else {
          _setPreparationDetail('Checking local resources · $checked/$total',
              '正在检查本地资源 · $checked/$total', '正在檢查本機資源 · $checked/$total');
        }
      },
    );
    _checkRun(run);
    _needsMoreContent = preparer.needsMoreContent;
  }

  Future<void> _loadNextQuestion(ReviewPreparationRun run) async {
    _checkRun(run);
    final languageCode = FFLocalizations.of(context).languageCode;
    var session = _session;
    if (session == null) return;
    while (!session!.isComplete) {
      _checkRun(run);
      final question = await run.wait(_repository.buildQuestion(
        session,
        languageCode,
      ));
      _checkRun(run);
      if (question != null) {
        if (!mounted) return;
        setState(() {
          _session = session;
          _question = question;
          _answer = null;
          _selectedIndex = null;
          _submitting = false;
          _questionStartedAt = DateTime.now();
          _activeSegmentStarted ??= DateTime.now();
        });
        return;
      }
      final previousIndex = session.currentIndex;
      session =
          await run.wait(_repository.skipUnavailableTarget(_uid, session));
      _checkRun(run);
      if (session.currentIndex <= previousIndex) {
        throw StateError('review.question.didNotAdvance');
      }
      _session = session;
    }
    if (session.completedCount == 0) {
      // Missing examples/options must not look like a completed study round.
      await run.wait(_repository.finishSession(
          uid: _uid,
          sessionId: session.id,
          completed: false,
          activeMs: _activeMs));
      _checkRun(run);
      _session = null;
      _question = null;
      await _refreshEmptyState(run);
      return;
    }
    await _completeRound(run);
  }

  Future<void> _submit(int selectedIndex) async {
    if (!_accountIsCurrent) {
      await _requestExit();
      return;
    }
    final session = _session;
    final question = _question;
    if (session == null || question == null || _submitting || _answer != null) {
      return;
    }
    _cancelCorrectAdvance();
    setState(() {
      _submitting = true;
      _selectedIndex = selectedIndex;
    });
    HapticFeedback.selectionClick();
    try {
      final latency = _questionStartedAt == null
          ? 0
          : DateTime.now().difference(_questionStartedAt!).inMilliseconds;
      final result = await _repository.recordAnswer(
        uid: _uid,
        session: session,
        question: question,
        selectedIndex: selectedIndex,
        latencyMs: latency,
        activeMs: _activeMs,
      );
      final updated = await _repository.sessionById(session.id);
      if (!mounted) return;
      if (!_accountIsCurrent) {
        await _requestExit();
        return;
      }
      setState(() {
        _answer = result;
        _session = updated;
        _submitting = false;
        _activeSegmentMs = 0;
        _activeSegmentStarted = DateTime.now();
      });
      if (result.correct) {
        HapticFeedback.lightImpact();
        _scheduleCorrectAdvance(question.target.targetId);
      } else {
        HapticFeedback.mediumImpact();
      }
    } catch (error, stackTrace) {
      _logDeveloperError('review.recordAnswer', error, stackTrace);
      if (!mounted) return;
      if (!_accountIsCurrent) {
        await _requestExit();
        return;
      }
      if (await _recoverAdvancedAnswer(session, question)) return;
      if (!mounted) return;
      if (!_accountIsCurrent) {
        await _requestExit();
        return;
      }
      setState(() {
        _submitting = false;
        _selectedIndex = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_t(
          'Progress was not saved. Please try again.',
          '进度尚未保存，请重试。',
          '進度尚未儲存，請重試。',
        ))),
      );
    }
  }

  Future<bool> _recoverAdvancedAnswer(
      ReviewSessionState previous, ReviewQuestion question) async {
    try {
      final restored = await _repository
          .sessionById(previous.id)
          .timeout(const Duration(seconds: 2));
      final target = await _repository
          .targetById(question.target.targetId)
          .timeout(const Duration(seconds: 2));
      if (!mounted || !_accountIsCurrent) return false;
      if (restored.currentIndex <= previous.currentIndex &&
          target != null &&
          target.stage == question.target.stage) {
        return false;
      }
      // A write may have committed before its acknowledgement failed, or a
      // second device may have advanced this word. Recover the saved position
      // instead of repeatedly submitting an answer that is already obsolete.
      setState(() {
        _session = restored;
        _submitting = false;
        _selectedIndex = null;
        _activeSegmentMs = 0;
        _activeSegmentStarted = null;
      });
      await _advanceToNext(showPreparation: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _continue() => _advanceToNext(showPreparation: true);

  Future<void> _advanceToNext({required bool showPreparation}) async {
    if (!_accountIsCurrent) {
      await _requestExit();
      return;
    }
    if (!mounted || _submitting || _advancing || _exitDialogOpen) return;
    _advancing = true;
    _stopPronunciation();
    _preparationRun?.cancel();
    final run = ReviewPreparationRun(budget: widget.preparationBudget);
    _preparationRun = run;
    _cancelCorrectAdvance();
    if (showPreparation) {
      setState(() {
        _loading = true;
        _preparationDetail = _t(
          'Preparing the next question locally…',
          '正在本地准备下一题…',
          '正在本機準備下一題…',
        );
      });
    }
    try {
      await _loadNextQuestion(run);
      if (_ownsRun(run) && showPreparation) setState(() => _loading = false);
    } on ReviewPreparationCancelled {
      // Exiting during a native query never revives a disposed page.
    } catch (error, stackTrace) {
      _logDeveloperError('review.nextQuestion', error, stackTrace);
      if (_ownsRun(run)) {
        setState(() {
          if (showPreparation) _loading = false;
          _error = _t('Unable to prepare the next question. Please retry.',
              '暂时无法准备下一题，请重试。', '暫時無法準備下一題，請重試。');
        });
      }
    } finally {
      _advancing = false;
    }
  }

  Future<void> _completeRound(ReviewPreparationRun run) async {
    if (_completing) return;
    final session = _session;
    if (session == null) return;
    _cancelCorrectAdvance();
    _completing = true;
    _stopPronunciation();
    _pauseActiveTimer();
    try {
      final summary = await run.wait(_repository.finishSession(
        uid: _uid,
        sessionId: session.id,
        completed: true,
        activeMs: _activeMs,
      ));
      _checkRun(run);
      final celebration = summary.completed >= 20;
      if (celebration) {
        unawaited(HapticFeedback.mediumImpact());
      }
      final again = await _showSummary(
        summary,
        celebration: celebration,
      );
      if (!mounted) return;
      if (again == true) {
        _completing = false;
        await _startNewRound();
      } else {
        context.pop();
      }
    } finally {
      _completing = false;
    }
  }

  Future<void> _startNewRound() async {
    _session = null;
    await _initialize();
  }

  Future<void> _requestExit() async {
    _stopPronunciation();
    if (!_accountIsCurrent) {
      _preparationRun?.cancel();
      _cancelCorrectAdvance();
      if (mounted) context.pop();
      return;
    }
    if (_exitDialogOpen || _completing) return;
    if (_loading || _error != null) {
      _preparationRun?.cancel();
      if (mounted) context.pop();
      return;
    }
    final session = _session;
    if (session == null) {
      if (mounted) context.pop();
      return;
    }
    _cancelCorrectAdvance();
    _exitDialogOpen = true;
    _pauseActiveTimer();
    try {
      final career = await _repository.careerLearnedCount(_uid);
      if (!mounted) return;
      final continueReview = await showWordAIGlassDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _GlassDialog(
          icon: Icons.pause_rounded,
          title: _t('Pause this round?', '暂停本轮？', '暫停本輪？'),
          summary: ReviewSummary(
            completed: session.completedCount,
            contextPassed: session.contextPassedCount,
            newLearned: session.newLearnedCount,
            activeMs: _activeMs,
            careerLearned: career,
          ),
          primaryLabel: _t('Continue', '继续', '繼續'),
          secondaryLabel: _t('End round', '结束本轮', '結束本輪'),
          onPrimary: () => Navigator.pop(dialogContext, true),
          onSecondary: () => Navigator.pop(dialogContext, false),
        ),
      );
      if (!mounted) return;
      if (continueReview != false) {
        _activeSegmentStarted = DateTime.now();
        if (_answer?.correct == true) {
          _scheduleCorrectAdvance(_question?.target.targetId);
        }
        return;
      }
      await _repository.finishSession(
        uid: _uid,
        sessionId: session.id,
        completed: false,
        activeMs: _activeMs,
      );
      if (mounted) context.pop();
    } catch (error, stackTrace) {
      _logDeveloperError('review.pause', error, stackTrace);
      if (mounted) {
        _activeSegmentStarted = DateTime.now();
        if (_answer?.correct == true) {
          _scheduleCorrectAdvance(_question?.target.targetId);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_t(
              'Unable to pause safely. Your completed answers are still saved.',
              '暂时无法暂停，已完成的答案仍已保存。',
              '暫時無法暫停，已完成的答案仍已儲存。',
            )),
          ),
        );
      }
    } finally {
      _exitDialogOpen = false;
    }
  }

  void _logDeveloperError(
    String operation,
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('$operation: ${error.runtimeType}');
  }

  Future<bool?> _showSummary(
    ReviewSummary summary, {
    required bool celebration,
  }) {
    return showWordAIGlassDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.58),
      builder: (dialogContext) => Stack(
        children: [
          if (celebration && !WordAIMotion.reduceMotion(dialogContext))
            const Positioned.fill(child: IgnorePointer(child: _Celebration())),
          _GlassDialog(
            icon: Icons.emoji_events_rounded,
            title: _t('Round complete', '本轮完成', '本輪完成'),
            summary: summary,
            celebration: celebration,
            primaryLabel: _t('Another round', '再来一轮', '再來一輪'),
            secondaryLabel: _t('Exit', '退出', '退出'),
            onPrimary: () => Navigator.pop(dialogContext, true),
            onSecondary: () => Navigator.pop(dialogContext, false),
          ),
        ],
      ),
    );
  }

  String _t(String en, String hans, String hant) {
    final code = FFLocalizations.of(context).languageCode;
    if (code == 'zh_Hant') return hant;
    if (code.startsWith('zh')) return hans;
    return en;
  }

  @override
  Widget build(BuildContext context) {
    _schedulePronunciation();
    final theme = FlutterFlowTheme.of(context);
    final session = _session;
    final question = _question;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestExit());
      },
      child: Scaffold(
        backgroundColor: theme.primaryBackground,
        body: SafeArea(
          child: Column(
            children: [
              _Header(
                progress: session == null || session.targetIds.isEmpty
                    ? 0
                    : session.currentIndex / session.targetIds.length,
                label: session == null
                    ? ''
                    : '${math.min(session.currentIndex + 1, session.targetIds.length)} / ${session.targetIds.length}',
                onClose: _requestExit,
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration:
                      WordAIMotion.duration(context, WordAIMotion.standard),
                  switchInCurve: WordAIMotion.emphasizedCurve,
                  switchOutCurve: WordAIMotion.exitCurve,
                  child: _loading
                      ? ReviewLoadingView(
                          key: const ValueKey('loading'),
                          text: _t(
                            'Preparing your review…',
                            '正在准备复习…',
                            '正在準備複習…',
                          ),
                          detail: _preparationDetail.isEmpty
                              ? _t('Restoring learning progress…', '正在恢复学习进度…',
                                  '正在恢復學習進度…')
                              : _preparationDetail,
                          hint: _t(
                              'You can leave at any time. Your progress is saved.',
                              '可随时退出，已完成的进度会保留。',
                              '可隨時退出，已完成的進度會保留。'),
                        )
                      : _error != null
                          ? _ErrorState(
                              key: const ValueKey('error'),
                              text: _error!,
                              retry: _initialize,
                              title: _t(
                                'Unable to prepare review',
                                '暂时无法准备复习',
                                '暫時無法準備複習',
                              ),
                              retryLabel: _t('Retry', '重试', '重試'),
                            )
                          : question == null
                              ? _EmptyState(
                                  key: const ValueKey('empty'),
                                  title: _needsMoreContent
                                      ? _t('A few entries still need preparing',
                                          '部分词条尚未准备好', '部分詞條尚未準備好')
                                      : _t(
                                          'Nothing to review',
                                          '暂无需要复习的词',
                                          '暫無需要複習的詞',
                                        ),
                                  message: _needsMoreContent
                                      ? _t(
                                          'You still have words to learn. Some local content is not ready yet. Retry when it is available; your progress is saved.',
                                          '你仍有未学词，部分本地内容暂未就绪。内容准备好后可重试，学习进度已保留。',
                                          '你仍有未學詞，部分本機內容暫未就緒。內容準備好後可重試，學習進度已保留。')
                                      : _wordsFromRoute().isEmpty
                                          ? _t(
                                              'Favorite a word to start learning.',
                                              '收藏一个词，即可开始学习。',
                                              '收藏一個詞，即可開始學習。',
                                            )
                                          : _t(
                                              'You have learned the meanings in this collection. Add more words whenever you are ready.',
                                              '当前词集的词义已学会，随时可以添加新词继续学习。',
                                              '目前詞集的詞義已學會，隨時可以新增詞語繼續學習。',
                                            ),
                                  buttonLabel: _needsMoreContent
                                      ? _t('Retry', '重试', '重試')
                                      : _t('Done', '完成', '完成'),
                                  onExit: _needsMoreContent
                                      ? _initialize
                                      : () => context.pop(),
                                )
                              : _QuestionView(
                                  key: ValueKey(question.target.targetId),
                                  question: question,
                                  answer: _answer,
                                  selectedIndex: _selectedIndex,
                                  submitting: _submitting,
                                  onSelect: _submit,
                                  onContinue: _continue,
                                  unsureLabel: _t('Not sure', '不确定', '不確定'),
                                  continueLabel: _t('Continue', '继续', '繼續'),
                                  contextLabel: _t(
                                    'Read it in context',
                                    '在语境中理解',
                                    '在語境中理解',
                                  ),
                                  independentLabel: _t(
                                    'Recognize it on its own',
                                    '独立识别',
                                    '獨立識別',
                                  ),
                                  incorrectLabel: _t(
                                    'Keep this meaning in progress',
                                    '这个词义会继续保留在学习中',
                                    '這個詞義會繼續保留在學習中',
                                  ),
                                ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.progress,
    required this.label,
    required this.onClose,
  });

  final double progress;
  final String label;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 18, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 6,
                backgroundColor: theme.alternate.withValues(alpha: 0.45),
                valueColor: AlwaysStoppedAnimation(theme.primary),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(label, style: theme.labelMedium),
        ],
      ),
    );
  }
}

class _QuestionView extends StatelessWidget {
  const _QuestionView({
    super.key,
    required this.question,
    required this.answer,
    required this.selectedIndex,
    required this.submitting,
    required this.onSelect,
    required this.onContinue,
    required this.unsureLabel,
    required this.continueLabel,
    required this.contextLabel,
    required this.independentLabel,
    required this.incorrectLabel,
  });

  final ReviewQuestion question;
  final ReviewAnswerResult? answer;
  final int? selectedIndex;
  final bool submitting;
  final ValueChanged<int> onSelect;
  final VoidCallback onContinue;
  final String unsureLabel;
  final String continueLabel;
  final String contextLabel;
  final String independentLabel;
  final String incorrectLabel;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final contextTest = question.type == ReviewTestType.context;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            contextTest ? contextLabel : independentLabel,
            style: theme.labelLarge.override(
              fontFamily: null,
              color: theme.primary,
              letterSpacing: 0,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          _GlassSurface(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: contextTest
                  ? _HighlightedSentence(
                      sentence: question.target.exampleEnglish,
                      target: question.target.targetForm,
                    )
                  : Column(
                      children: [
                        Text(
                          question.target.word,
                          textAlign: TextAlign.center,
                          style: theme.displaySmall.override(
                            fontFamily: null,
                            fontSize: 38,
                            letterSpacing: -0.6,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          question.target.partOfSpeech,
                          style: theme.bodyMedium.override(
                            fontFamily: null,
                            color: theme.secondaryText,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 18),
          for (var index = 0; index < question.options.length; index++) ...[
            _OptionButton(
              text: question.options[index],
              selected: selectedIndex == index,
              correct: answer == null ? null : index == question.correctIndex,
              disabled: submitting || answer != null,
              onTap: () => onSelect(index),
            ),
            const SizedBox(height: 10),
          ],
          TextButton.icon(
            onPressed: submitting || answer != null ? null : () => onSelect(-1),
            icon: const Icon(Icons.help_outline_rounded, size: 18),
            label: Text(unsureLabel),
          ),
          if (answer != null && !answer!.correct) ...[
            const SizedBox(height: 14),
            _Feedback(
              title: incorrectLabel,
              correctMeaning: question.options[question.correctIndex],
              passed: answer!.wordPassedSenses,
              total: answer!.wordTotalSenses,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onContinue,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(continueLabel),
            ),
          ],
        ],
      ),
    );
  }
}

class _HighlightedSentence extends StatelessWidget {
  const _HighlightedSentence({required this.sentence, required this.target});

  final String sentence;
  final String target;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final lower = sentence.toLowerCase();
    final index = lower.indexOf(target.toLowerCase());
    final normal = theme.titleLarge.override(
      fontFamily: null,
      fontSize: 24,
      lineHeight: 1.42,
      letterSpacing: -0.15,
      fontWeight: FontWeight.w500,
    );
    if (index < 0 || target.isEmpty) {
      return Text(sentence, textAlign: TextAlign.center, style: normal);
    }
    return Text.rich(
      TextSpan(
        style: normal,
        children: [
          TextSpan(text: sentence.substring(0, index)),
          TextSpan(
            text: sentence.substring(index, index + target.length),
            style: normal.copyWith(
              color: theme.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: sentence.substring(index + target.length)),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.text,
    required this.selected,
    required this.correct,
    required this.disabled,
    required this.onTap,
  });

  final String text;
  final bool selected;
  final bool? correct;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final color = correct == true
        ? theme.success
        : correct == false && selected
            ? theme.error
            : selected
                ? theme.primary
                : theme.alternate;
    return AnimatedContainer(
      duration: WordAIMotion.duration(context, WordAIMotion.quick),
      curve: WordAIMotion.emphasizedCurve,
      decoration: BoxDecoration(
        color:
            color.withValues(alpha: selected || correct == true ? 0.13 : 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.58)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(18),
          // The animated selection color already provides tap feedback.
          // A separate ink splash flashes as the option becomes disabled.
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: theme.bodyLarge.override(
                      fontFamily: null,
                      letterSpacing: 0,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // Keep the text width and row height unchanged when the
                // saved answer adds its result icon.
                const SizedBox(width: 8),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: correct == true
                      ? Icon(Icons.check_circle_rounded,
                          color: theme.success, size: 24)
                      : correct == false && selected
                          ? Icon(Icons.cancel_rounded,
                              color: theme.error, size: 24)
                          : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Feedback extends StatelessWidget {
  const _Feedback({
    required this.title,
    required this.correctMeaning,
    required this.passed,
    required this.total,
  });

  final String title;
  final String correctMeaning;
  final int passed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    return _GlassSurface(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lightbulb_rounded,
                  color: theme.warning,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    title,
                    style: theme.titleMedium.override(
                      fontFamily: null,
                      letterSpacing: 0,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text('$passed/$total', style: theme.labelMedium),
              ],
            ),
            const SizedBox(height: 12),
            Text(correctMeaning, style: theme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.secondaryBackground.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: theme.alternate.withValues(alpha: 0.62)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x18000000),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _GlassDialog extends StatelessWidget {
  const _GlassDialog({
    required this.icon,
    required this.title,
    required this.summary,
    required this.primaryLabel,
    required this.secondaryLabel,
    required this.onPrimary,
    required this.onSecondary,
    this.celebration = false,
  });

  final IconData icon;
  final String title;
  final ReviewSummary summary;
  final String primaryLabel;
  final String secondaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;
  final bool celebration;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final languageCode = FFLocalizations.of(context).languageCode;
    String label(String en, String hans, String hant) {
      if (languageCode == 'zh_Hant') return hant;
      if (languageCode.startsWith('zh')) return hans;
      return en;
    }

    final reduceMotion = WordAIMotion.reduceMotion(context);
    final dialog = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Material(
          color: Colors.transparent,
          child: _GlassSurface(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: celebration ? 0.72 : 1, end: 1),
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 620),
                      curve: Curves.elasticOut,
                      builder: (context, scale, child) => Transform.scale(
                        scale: scale,
                        child: child,
                      ),
                      child: Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              theme.primary.withValues(alpha: 0.24),
                              theme.primary.withValues(alpha: 0.07),
                            ],
                          ),
                          border: Border.all(
                            color: theme.primary.withValues(alpha: 0.24),
                          ),
                          boxShadow: celebration
                              ? [
                                  BoxShadow(
                                    color:
                                        theme.primary.withValues(alpha: 0.24),
                                    blurRadius: 28,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : const [],
                        ),
                        child: Icon(icon, size: 36, color: theme.primary),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: theme.headlineSmall.override(
                        fontFamily: null,
                        letterSpacing: -0.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (celebration) ...[
                      const SizedBox(height: 7),
                      Text(
                        summary.newLearned > 0
                            ? label(
                                '${summary.completed} words moved forward · ${summary.newLearned} newly learned',
                                '本轮推进 ${summary.completed} 个词 · 新学会 ${summary.newLearned} 个',
                                '本輪推進 ${summary.completed} 個詞 · 新學會 ${summary.newLearned} 個',
                              )
                            : label(
                                '${summary.completed} words moved forward',
                                '本轮推进了 ${summary.completed} 个词',
                                '本輪推進了 ${summary.completed} 個詞',
                              ),
                        textAlign: TextAlign.center,
                        style: theme.bodyMedium.copyWith(
                          color: theme.secondaryText,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: [
                        _Stat(
                          value: summary.completed,
                          label: label('Done', '已完成', '已完成'),
                          icon: Icons.check_rounded,
                          animate: celebration,
                          animationOrder: 0,
                        ),
                        _Stat(
                          value: summary.contextPassed,
                          label: label('Context', '语境通过', '語境通過'),
                          icon: Icons.format_quote_rounded,
                          animate: celebration,
                          animationOrder: 1,
                        ),
                        _Stat(
                          value: summary.newLearned,
                          label: label('Learned', '新学会', '新學會'),
                          icon: Icons.auto_awesome_rounded,
                          animate: celebration,
                          animationOrder: 2,
                        ),
                        _Stat(
                          value: (summary.activeMs / 60000).ceil(),
                          suffix: 'm',
                          label: label('Active', '用时', '用時'),
                          icon: Icons.timer_outlined,
                          animate: celebration,
                          animationOrder: 3,
                        ),
                        _Stat(
                          value: summary.careerLearned,
                          label: label('Lifetime', '生涯学会', '生涯學會'),
                          icon: Icons.workspace_premium_rounded,
                          animate: celebration,
                          animationOrder: 4,
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: onPrimary,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(primaryLabel),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                        onPressed: onSecondary, child: Text(secondaryLabel)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!celebration || reduceMotion) return dialog;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.88, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (context, value, child) => Opacity(
        opacity: ((value - 0.88) / 0.12).clamp(0, 1),
        child: Transform.scale(scale: value, child: child),
      ),
      child: dialog,
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.value,
    required this.label,
    required this.icon,
    this.suffix = '',
    this.animate = false,
    this.animationOrder = 0,
  });
  final int value;
  final String label;
  final IconData icon;
  final String suffix;
  final bool animate;
  final int animationOrder;

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final shouldAnimate = animate && !WordAIMotion.reduceMotion(context);
    return Container(
      width: 92,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: theme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, size: 16, color: theme.primary),
          const SizedBox(height: 3),
          TweenAnimationBuilder<double>(
            tween: Tween(
                begin: shouldAnimate ? 0 : value.toDouble(),
                end: value.toDouble()),
            duration: shouldAnimate
                ? Duration(milliseconds: 650 + animationOrder * 110)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            builder: (context, animatedValue, _) => Text(
              '${animatedValue.round()}$suffix',
              style: theme.titleMedium.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(label, style: theme.labelSmall.copyWith(color: theme.primary)),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    super.key,
    required this.text,
    required this.retry,
    required this.title,
    required this.retryLabel,
  });
  final String text;
  final VoidCallback retry;
  final String title;
  final String retryLabel;
  @override
  Widget build(BuildContext context) => _EmptyState(
        title: title,
        message: text,
        onExit: retry,
        buttonLabel: retryLabel,
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    super.key,
    required this.title,
    required this.message,
    required this.onExit,
    this.buttonLabel = 'Done',
  });
  final String title;
  final String message;
  final VoidCallback onExit;
  final String buttonLabel;
  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: _GlassSurface(
          child: Padding(
            padding: const EdgeInsets.all(26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_stories_rounded,
                    size: 42, color: theme.primary),
                const SizedBox(height: 14),
                Text(title,
                    style: theme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 9),
                Text(message,
                    style: theme.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton(onPressed: onExit, child: Text(buttonLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Celebration extends StatefulWidget {
  const _Celebration();
  @override
  State<_Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<_Celebration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (_, __) => CustomPaint(
          painter: _CelebrationPainter(_controller.value),
        ),
      );
}

class _CelebrationPainter extends CustomPainter {
  const _CelebrationPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = [
      const Color(0xFF4DA3FF),
      const Color(0xFF73E2A7),
      const Color(0xFFFFCF5C),
      const Color(0xFFFF7D9C),
      const Color(0xFFA78BFA),
    ];

    // Long curling ribbons make the celebration read as a deliberate reward,
    // while the shorter pieces keep the effect light enough for the dialog.
    for (var i = 0; i < 14; i++) {
      final random = math.Random(4301 + i * 613);
      final delay = random.nextDouble() * 0.18;
      final local = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final startX = random.nextDouble() * size.width;
      final y = -60 + local * (size.height + 120);
      final amplitude = 20 + random.nextDouble() * 30;
      final phase = i * 1.7 + local * math.pi * 5;
      final path = Path()..moveTo(startX, y - 68);
      for (var step = 1; step <= 8; step++) {
        final fraction = step / 8;
        path.lineTo(
          startX + math.sin(phase + fraction * math.pi * 2) * amplitude,
          y - 68 + fraction * 76,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[i % colors.length]
              .withValues(alpha: (1 - local * 0.42).clamp(0, 1))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round,
      );
    }

    for (var i = 0; i < 72; i++) {
      final random = math.Random(i * 971);
      final x = random.nextDouble() * size.width;
      final delay = random.nextDouble() * 0.28;
      final local = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      final y = -20 + local * (size.height + 60);
      final drift = math.sin(local * math.pi * 3 + i) * 24;
      final paint = Paint()
        ..color = colors[i % colors.length]
            .withValues(alpha: (1 - local * 0.55).clamp(0, 1));
      canvas.save();
      canvas.translate(x + drift, y);
      canvas.rotate(local * math.pi * 4 + i);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-3, -7, 6, 14),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _CelebrationPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
