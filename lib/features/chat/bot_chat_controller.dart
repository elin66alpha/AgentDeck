import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_session.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/notifications/fcm_service.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/notifications/web_push.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/error_text.dart';
import 'agent_controls.dart';
import 'background_turn_registry.dart';

class BotChatController extends ChangeNotifier {
  BotChatController({BackendClient? backendClient})
      : _backendClient = backendClient ?? BackendClient();

  static const String _streamingKey = 'streaming';
  static const String _awaitingFirstTokenKey = 'awaitingFirstToken';
  static const String _deliveryFailedKey = 'deliveryFailed';
  static const String _errorDetailKey = 'errorDetail';
  static const String _systemKey = 'system';
  static const String _noticeKey = 'notice';
  static const String _requestIdKey = 'requestId';
  static const String _progressLinesKey = 'progressLines';
  static const String _cancelledKey = 'cancelled';
  static const String _segmentsKey = 'segments';
  static const String _queuedKey = 'queued';

  final BackendClient _backendClient;
  String? _activeWorkdir;

  CliAgent _agent = defaultCliAgents.first;
  MachineCredential? _machine;
  final Map<String, bool?> _authStatus = <String, bool?>{};
  final Map<String, List<AgentSession>> _sessionsByAgent =
      <String, List<AgentSession>>{};
  final Map<String, String> _activeSessionByAgent = <String, String>{};
  final Map<String, StringBuffer> _streamBuffers = <String, StringBuffer>{};
  // Per-request live segments mirroring the backend: the agent's mid-task
  // follow-up notes and its final answer are kept as separate, individually
  // timestamped messages instead of one growing block.
  final Map<String, List<_StreamSegment>> _streamSegments =
      <String, List<_StreamSegment>>{};
  final Set<String> _loadingSessions = <String>{};
  final List<ChatMessage> _messages = <ChatMessage>[];
  // Ids of follow-up messages typed while a turn was running, in send order.
  // They show as pending bubbles and are sent automatically, one at a time, as
  // each turn finishes — so the composer behaves like Claude Code / Codex.
  final List<String> _pendingQueue = <String>[];
  final BackgroundTurnRegistry _backgroundTurns = BackgroundTurnRegistry();
  final PendingDraftStore _pendingDrafts = PendingDraftStore();
  bool _historyLoading = false;
  // Increments on each context-switch load. The finally only clears the
  // spinner when its captured seq is still the latest, so a slow earlier load
  // settling after a newer one started can't flash the empty placeholder.
  int _historyLoadSeq = 0;
  bool _isCancelling = false;
  String? _lastError;
  // A turn is in flight on this device exactly while a request id is active;
  // `isThinking` derives from it so the two can't drift apart.
  String? _activeRequestId;
  AppLanguage _language = AppLanguage.en;
  StreamSubscription<BackendEvent>? _eventsSub;
  Timer? _eventReconnectTimer;
  Timer? _historyPollTimer;
  Timer? _remoteSettleTimer;
  Timer? _streamNotifyTimer;
  bool _wantsEvents = false;
  bool _streamNotifyQueued = false;
  // True while another device is running a turn on the conversation we are
  // viewing (same workdir + agent + session). We mirror it by polling the backend's
  // authoritative history rather than replaying its deltas, which keeps the two
  // views identical without delta/snapshot races.
  bool _remoteActive = false;
  // True only while THIS device's POST /api/chat SSE stream is actively driving
  // the current turn. When it is false, an in-flight turn (one we started whose
  // stream dropped, or one restored from history on a cold start) is mirrored
  // from shared history + events instead of a local stream. This gates both the
  // "ignore my own echo" event filter and the "don't clobber my stream" poll
  // skip, so a dropped/absent stream no longer blocks reattachment.
  bool _localStreamActive = false;
  // The requestId of a turn we reattached to after our stream dropped. Polling
  // ends the mirror once history shows this turn finalized, so we recover even
  // if the shared event stream misses the agent_done edge during the reconnect.
  String? _reattachRequestId;
  _ForegroundTurn? _foregroundTurn;
  int _quotaScheduleRevision = 0;
  bool _quotaPushEnabled = true;
  bool _taskPushEnabled = true;

  // A read-only view over the live list (O(1)), not a copy. The chat screen
  // reads this on every (throttled) streaming rebuild, so copying the whole
  // history each time was O(n) churn that grew with the conversation.
  List<ChatMessage> get messages =>
      UnmodifiableListView<ChatMessage>(_messages);
  int get messageCount => _messages.length;
  bool get isThinking => _activeRequestId != null;
  bool get isHistoryLoading => _historyLoading;
  bool get isCancelling => _isCancelling;
  String? get lastError => _lastError;
  CliAgent get agent => _agent;
  MachineCredential? get machine => _machine;
  // Exposed so the composer's per-agent Model/Effort/Permission controls can
  // reach the same backend client (and thus the same workdir scope).
  BackendClient get backend => _backendClient;
  // The work directory last switched to, so workspace-scoped UI (e.g. the swarm
  // drawer list) can reload when it changes without re-fetching on every notify.
  String? get activeWorkdir => _activeWorkdir;
  String? get activeSessionId => _activeSessionByAgent[_agent.key];
  AgentSession? get activeSession => sessionById(_agent.key, activeSessionId);
  int get quotaScheduleRevision => _quotaScheduleRevision;
  AppStrings get _strings => AppStrings(_language);

  String? activeSessionIdFor(String agentKey) =>
      _activeSessionByAgent[agentKey];

  AgentSession? activeSessionFor(String agentKey) {
    return sessionById(agentKey, activeSessionIdFor(agentKey));
  }

  List<AgentSession> sessionsFor(String agentKey) =>
      List<AgentSession>.unmodifiable(
        _sessionsByAgent[agentKey] ?? const <AgentSession>[],
      );

  bool sessionsLoadingFor(String agentKey) =>
      _loadingSessions.contains(agentKey);

  bool sessionRunning(String agentKey, String sessionId) {
    if (sessionId.isEmpty) return false;
    if (_agent.key == agentKey &&
        activeSessionId == sessionId &&
        (isThinking || _remoteActive)) {
      return true;
    }
    return _backgroundTurns.contains(agentKey, sessionId);
  }

  AgentSession? sessionById(String agentKey, String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return null;
    for (final AgentSession session
        in _sessionsByAgent[agentKey] ?? const <AgentSession>[]) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  String _sessionNameFor(String agentKey, String sessionId) =>
      sessionById(agentKey, sessionId)?.name ??
      (sessionId == AgentSession.defaultId ? 'Main' : sessionId);

  String _agentLabelFor(String agentKey) => cliAgentByKey(agentKey).label;

  /// Login state for an agent CLI on the backend host: true/false when known,
  /// or null when unchecked or undeterminable. Drives the
  /// "not logged in" banner; it never blocks sending, since detection is
  /// best-effort and a real failure is still caught when the turn runs.
  bool? agentLoggedIn(String agentKey) => _authStatus[agentKey];

  /// Refreshes per-agent login state from the backend. Best-effort: a probe
  /// failure (offline, older backend without the endpoint) is ignored.
  Future<void> refreshAuthStatus({bool verifyCredentials = false}) async {
    if (_machine == null) return;
    try {
      final Map<String, bool?> status = await _backendClient.fetchAuthStatus(
        verifyCredentials: verifyCredentials,
      );
      _authStatus
        ..clear()
        ..addAll(status);
      notifyListeners();
    } catch (_) {
      // A probe failure must not interfere with chatting.
    }
  }

  Future<AgentSessionList?> _refreshSessionsFor(String agentKey) async {
    final MachineCredential? machine = _machine;
    if (machine == null) return null;
    _loadingSessions.add(agentKey);
    notifyListeners();
    try {
      final AgentSessionList result = await _backendClient.fetchSessions(
        agentKey,
      );
      if (_machine?.id != machine.id) return null;
      _sessionsByAgent[agentKey] = result.sessions;
      _activeSessionByAgent[agentKey] = result.activeSession.id;
      return result;
    } finally {
      _loadingSessions.remove(agentKey);
      notifyListeners();
    }
  }

  void _clearSessionLists() {
    _sessionsByAgent.clear();
    _activeSessionByAgent.clear();
    _loadingSessions.clear();
  }

  void _prefetchInactiveSessions() {
    if (_machine == null) return;
    for (final CliAgent agent in defaultCliAgents) {
      if (agent.key == _agent.key || _sessionsByAgent.containsKey(agent.key)) {
        continue;
      }
      unawaited(_refreshSessionsFor(agent.key).catchError((_) => null));
    }
  }

  Future<String> _ensureActiveSessionId(CliAgent agent) async {
    final String? current = _activeSessionByAgent[agent.key];
    if (current != null && current.isNotEmpty) return current;
    final AgentSessionList? result = await _refreshSessionsFor(agent.key);
    final AgentSession? active = result?.activeSession;
    if (active != null) return active.id;
    return AgentSession.defaultId;
  }

  Future<void> createSessionFor(CliAgent agent, {String name = ''}) async {
    final MachineCredential? machine = _machine;
    if (machine == null) return;
    final AgentSessionList result = await _backendClient.createSession(
      agent.key,
      name,
    );
    if (_machine?.id != machine.id) return;
    _detachVisibleTurnForContextSwitch();
    _sessionsByAgent[agent.key] = result.sessions;
    _activeSessionByAgent[agent.key] = result.activeSession.id;
    _agent = agent;
    await _reloadConversation();
  }

  Future<void> selectSession(CliAgent agent, String sessionId) async {
    final MachineCredential? machine = _machine;
    if (machine == null || sessionId.isEmpty) return;
    if (_agent.key == agent.key && activeSessionId == sessionId) return;
    final AgentSessionList result = await _backendClient.selectSession(
      agent.key,
      sessionId,
    );
    if (_machine?.id != machine.id) return;
    _detachVisibleTurnForContextSwitch();
    final BackgroundTurn? reattachTurn = _takeBackgroundTurn(
      agent.key,
      result.activeSession.id,
    );
    _sessionsByAgent[agent.key] = result.sessions;
    _activeSessionByAgent[agent.key] = result.activeSession.id;
    _agent = agent;
    await _reloadConversation(reattachTurn: reattachTurn);
  }

  Future<void> deleteSession(CliAgent agent, String sessionId) async {
    final MachineCredential? machine = _machine;
    if (machine == null || sessionId.isEmpty) return;
    final bool deletedVisible =
        _agent.key == agent.key && activeSessionId == sessionId;
    final AgentSessionList result = await _backendClient.deleteSession(
      agent.key,
      sessionId,
    );
    if (_machine?.id != machine.id) return;
    _sessionsByAgent[agent.key] = result.sessions;
    _activeSessionByAgent[agent.key] = result.activeSession.id;
    if (deletedVisible) {
      await _reloadConversation();
    } else {
      notifyListeners();
    }
  }

  void setLanguage(AppLanguage language) {
    _language = language;
  }

  void setNotificationPreferences({
    required bool quotaPushEnabled,
    required bool taskPushEnabled,
  }) {
    if (_quotaPushEnabled == quotaPushEnabled &&
        _taskPushEnabled == taskPushEnabled) {
      return;
    }
    _quotaPushEnabled = quotaPushEnabled;
    _taskPushEnabled = taskPushEnabled;
    _pushSynced = false;
    _fcmSynced = false;
  }

  bool isRetryable(ChatMessage message) =>
      message.isUser && message.metadata[_deliveryFailedKey] == true;

  bool isAwaitingFirstToken(ChatMessage message) =>
      message.metadata[_awaitingFirstTokenKey] == true;

  bool isStreaming(ChatMessage message) =>
      message.metadata[_streamingKey] == true;

  bool isSystemMessage(ChatMessage message) =>
      message.metadata[_systemKey] == true;

  // A notice is an ephemeral, centered one-liner (e.g. "Conversation
  // compacted") rather than a chat bubble. It lives only in the in-memory
  // message list, so it disappears on the next history reload.
  bool isNoticeMessage(ChatMessage message) =>
      message.metadata[_noticeKey] == true;

  bool isCancelled(ChatMessage message) =>
      message.metadata[_cancelledKey] == true;

  String? errorDetailFor(ChatMessage message) =>
      message.metadata[_errorDetailKey] as String?;

  List<String> progressLinesFor(ChatMessage message) {
    if (message.metadata[_streamingKey] != true) return const <String>[];
    final Object? raw = message.metadata[_progressLinesKey];
    if (raw is List<String>) return raw;
    if (raw is! List) return const <String>[];
    return raw.whereType<String>().toList(growable: false);
  }

  Future<void> loadFor(CliAgent agent, MachineCredential machine) async {
    // The app keeps no local chat history: the backend (CLI host) owns it and
    // we fetch it back here. Keep the in-memory messages while the agent/machine
    // is unchanged; switching either starts fresh and reloads from the backend.
    final bool sameContext =
        _agent.key == agent.key && _machine?.id == machine.id;
    final bool machineChanged = _machine?.id != machine.id;
    if (!sameContext) _detachVisibleTurnForContextSwitch();
    final String? targetSessionId = _activeSessionByAgent[agent.key];
    final BackgroundTurn? reattachTurn = targetSessionId == null
        ? null
        : _takeBackgroundTurn(agent.key, targetSessionId);
    _agent = agent;
    _machine = machine;
    if (machineChanged) {
      _clearSessionLists();
      _clearBackgroundTurns();
      _pendingDrafts.clear();
      // Another host can have different CLIs, versions, and quota.
      clearAgentOptionsCache();
      _lastUsageReport = null;
      unawaited(refreshWorkdir());
    }
    if (sameContext && activeSessionId != null) {
      notifyListeners();
      return;
    }
    await _resetAndReloadConversation(
      agent,
      machine,
      skipIfMessagesExist: true,
      afterReset: _prefetchInactiveSessions,
      reattachTurn: reattachTurn,
    );
  }

  void goHome() {
    if (isThinking || _remoteActive) return;
    if (_machine == null && _messages.isEmpty && !_historyLoading) return;
    _machine = null;
    _messages.clear();
    _clearStreamBuffers();
    _pendingQueue.clear();
    _historyLoading = false;
    _lastError = null;
    _isCancelling = false;
    _activeRequestId = null;
    _localStreamActive = false;
    _reattachRequestId = null;
    _remoteActive = false;
    _remoteSettleTimer?.cancel();
    _stopHistoryPolling();
    _clearBackgroundTurns();
    _pendingDrafts.clear();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    final CliAgent agent = _agent;
    final String sessionId = await _ensureActiveSessionId(agent);
    // Reset the machine-side session first; otherwise the next prompt may
    // resume context that the user just cleared locally. Only wipe the on-screen
    // history once the backend confirms — if the clear fails (e.g. a turn is
    // running → SESSION_BUSY), keep the messages so the view doesn't lie.
    try {
      await _backendClient.clearSession(agent.key, sessionId);
      await _refreshSessionsFor(agent.key);
    } catch (err) {
      _appendSystemMessage(_strings.localChatSessionResetFailed(err));
      return;
    }
    _stopHistoryPolling();
    _messages.clear();
    _clearStreamBuffers();
    _pendingQueue.clear();
    _lastError = null;
    notifyListeners();
  }

  Future<void> compressConversation() async {
    if (isThinking || _machine == null) return;
    _isCancelling = false;
    _lastError = null;
    final String requestId = _newRequestId(_agent);
    _activeRequestId = requestId;
    notifyListeners();
    try {
      final String sessionId = await _ensureActiveSessionId(_agent);
      await _backendClient.compressConversation(
        agentKey: _agent.key,
        sessionId: sessionId,
        requestId: requestId,
      );
    } catch (err) {
      _lastError = _friendlyError(err);
      rethrow;
    } finally {
      if (_activeRequestId == requestId) _activeRequestId = null;
      _isCancelling = false;
      notifyListeners();
    }
  }

  Future<void> sendUserText(String rawText) async {
    final String text = rawText.trim();
    if (text.isEmpty || _machine == null) return;

    final ChatMessage userMessage = ChatMessage.user(text);
    // A turn is already running (ours or mirrored): hold this as a pending
    // follow-up and let it auto-send when the conversation frees up.
    if (isThinking || _remoteActive) {
      _messages.add(
        userMessage.copyWith(metadata: <String, Object?>{_queuedKey: true}),
      );
      _pendingQueue.add(userMessage.id);
      notifyListeners();
      return;
    }

    _messages.add(userMessage);
    notifyListeners();
    await _runTurn(_agent, userMessage);
  }

  bool isQueued(ChatMessage message) =>
      message.metadata[_queuedKey] == true &&
      _pendingQueue.contains(message.id);

  /// Remove a not-yet-sent follow-up from the queue.
  void cancelQueued(ChatMessage message) {
    if (!isQueued(message)) return;
    _pendingQueue.remove(message.id);
    _messages.removeWhere((ChatMessage m) => m.id == message.id);
    notifyListeners();
  }

  // Send the next pending follow-up if the conversation is idle. Safe to call
  // from any turn-end path; the guards make it a no-op while anything is active.
  Future<void> _maybeDrainQueue() async {
    if (_machine == null || isThinking || _localStreamActive || _remoteActive) {
      return;
    }
    while (_pendingQueue.isNotEmpty) {
      final String id = _pendingQueue.removeAt(0);
      final int index = _messages.indexWhere((ChatMessage m) => m.id == id);
      if (index == -1) continue; // cancelled before its turn came up
      // Promote the pending bubble to a normal sent message.
      _messages[index] =
          _messages[index].copyWith(metadata: const <String, Object?>{});
      notifyListeners();
      await _runTurn(_agent, _messages[index]);
      return; // remaining items drain when this turn ends
    }
  }

  Future<void> cancelActiveTurn() async {
    final String? requestId = _activeRequestId;
    if (!isThinking || _isCancelling || requestId == null) return;
    _isCancelling = true;
    notifyListeners();
    try {
      await _backendClient.cancelMessage(requestId);
    } catch (err) {
      if (err is BackendException && err.code == 'REQUEST_NOT_FOUND') {
        // The request already finished. Let _runTurn finish with the real
        // outcome instead of forcing a cancelled state here.
        return;
      }
      _lastError = _friendlyError(err);
    } finally {
      notifyListeners();
    }
  }

  Future<void> retry(ChatMessage message) async {
    if (isThinking || _machine == null || !isRetryable(message)) return;
    final int index = _messages.indexWhere(
      (ChatMessage m) => m.id == message.id,
    );
    if (index == -1) return;
    _messages[index] = message.copyWith(metadata: const <String, Object?>{});
    notifyListeners();
    await _runTurn(_agent, _messages[index]);
  }

  Future<String> statusText(
    AppStrings strings, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final BackendDiagnostics diagnostics = await _backendClient.diagnostics(
        timeout: timeout,
      );
      return diagnostics.toDisplayText(strings);
    } on BackendException catch (err) {
      if (err.status != 404) rethrow;
      final BackendStatus status = await _backendClient.status(
        timeout: timeout,
      );
      return status.toDisplayText(strings);
    }
  }

  UsageReport? _lastUsageReport;

  /// The most recent quota report, kept so the usage and scheduler screens can
  /// paint the previous numbers immediately instead of holding a spinner for a
  /// round trip that reaches Anthropic and OpenAI. Cleared on a machine switch,
  /// since quota belongs to the host's credentials.
  UsageReport? get lastUsageReport => _lastUsageReport;

  /// Queries every quota source, or only [source]. A single-source result is
  /// merged into [lastUsageReport] and the merged report returned, so sources
  /// queried separately can land one at a time.
  Future<UsageReport> usageReport({String? source}) async {
    final UsageReport report = await _backendClient.usageReport(source: source);
    final UsageReport? last = _lastUsageReport;
    return _lastUsageReport =
        source == null || last == null ? report : last.merge(report);
  }

  // Registers this browser for Web Push so quota/scheduled-message alerts arrive
  // even when the tab is closed. Web-only and best-effort: a no-op off the web,
  // when the backend has no VAPID keys, or until the user grants permission
  // (retried on the next app open). Runs at most once per session.
  bool _pushSynced = false;
  // Set only once a subscription is registered with the backend, so it means
  // "push will reach this browser" rather than "we finished trying".
  bool _webPushActive = false;
  Future<void> syncPushSubscription({bool force = false}) async {
    if ((!force && _pushSynced) || _machine == null || !webPushSupported()) {
      return;
    }
    try {
      final PushConfig config = await _backendClient.pushConfig();
      if (!config.enabled || config.publicKey.isEmpty) {
        _pushSynced = true;
        return;
      }
      final String? subscription = await webPushSubscribe(config.publicKey);
      if (subscription == null) return; // permission not granted yet
      await _backendClient.subscribePush(
        subscription,
        _strings.isZh ? 'zh' : 'en',
        quotaPushEnabled: _quotaPushEnabled,
        taskPushEnabled: _taskPushEnabled,
      );
      _pushSynced = true;
      _webPushActive = true;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }

  // Registers this mobile device for FCM so quota/scheduled-message alerts can
  // arrive while the app is backgrounded or killed. Android/iOS only and
  // best-effort; web/desktop and missing Firebase config are no-ops.
  bool _fcmSynced = false;
  Future<void> syncFcmRegistration({bool force = false}) async {
    if ((!force && _fcmSynced) || _machine == null) return;
    try {
      final bool handled = await FcmService.instance.syncRegistration(
        backendClient: _backendClient,
        lang: _strings.isZh ? 'zh' : 'en',
        quotaPushEnabled: _quotaPushEnabled,
        taskPushEnabled: _taskPushEnabled,
      );
      if (handled) _fcmSynced = true;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }

  Future<List<DeviceToken>> deviceTokens() => _backendClient.deviceTokens();

  Future<void> revokeDeviceToken(String id) =>
      _backendClient.revokeDeviceToken(id);

  Future<void> deleteDeviceToken(String id) =>
      _backendClient.deleteDeviceToken(id);

  Future<List<ChatHistorySearchResult>> searchHistory(
    String query, {
    bool currentAgentOnly = false,
  }) {
    return _backendClient.searchHistory(
      query,
      agentKey: currentAgentOnly ? _agent.key : null,
    );
  }

  Future<ConversationExport> exportCurrentSessionMarkdown() async {
    final String sessionId = await _ensureActiveSessionId(_agent);
    return _backendClient.exportHistory(_agent.key, sessionId: sessionId);
  }

  Future<List<QuotaSchedule>> quotaSchedules() =>
      _backendClient.quotaSchedules();

  Future<QuotaSchedule> createQuotaSchedule({
    required String sourceKey,
    required String agentKey,
    required String prompt,
    String? targetResetsAt,
    bool replaceExisting = false,
  }) async {
    final CliAgent agent = cliAgentByKey(agentKey);
    final String sessionId = await _ensureActiveSessionId(agent);
    return _backendClient.createQuotaSchedule(
      sourceKey: sourceKey,
      agentKey: agent.key,
      sessionId: sessionId,
      prompt: prompt,
      targetResetsAt: targetResetsAt,
      replaceExisting: replaceExisting,
    );
  }

  Future<void> cancelQuotaSchedule(String id) =>
      _backendClient.cancelQuotaSchedule(id);

  Future<WorkdirInfo> workdir() => _backendClient.workdir();

  /// Pulls this device's current work directory: its stored path, or the
  /// backend default before one is chosen. Best-effort.
  Future<void> refreshWorkdir() async {
    try {
      final WorkdirInfo info = await _backendClient.workdir();
      if (info.dir == _activeWorkdir) return;
      _activeWorkdir = info.dir;
      notifyListeners();
    } catch (_) {
      // Keep the last known path while the backend is unreachable.
    }
  }

  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    final WorkdirInfo info = await _backendClient.setWorkdir(
      path,
      create: create,
    );
    _activeWorkdir = info.dir;
    // Switching paths switches conversations: the session is keyed by
    // workdir + agent + chat session. Reconnect the event stream with the new
    // workdir and reload the shared history for this path so it shows immediately.
    _detachVisibleTurnForContextSwitch();
    _clearBackgroundTurns();
    _pendingDrafts.clear();
    _clearSessionLists();
    await reconnectEvents();
    await _reloadConversation();
    return info;
  }

  /// Clears the view and pulls the shared conversation for the current
  /// workdir + agent + session. Used after switching the work directory.
  Future<void> _reloadConversation({BackgroundTurn? reattachTurn}) async {
    final MachineCredential? machine = _machine;
    if (machine == null) return;
    final CliAgent agent = _agent;
    await _resetAndReloadConversation(
      agent,
      machine,
      skipIfMessagesExist: false,
      reattachTurn: reattachTurn,
    );
    _prefetchInactiveSessions();
  }

  Future<void> _resetAndReloadConversation(
    CliAgent agent,
    MachineCredential machine, {
    required bool skipIfMessagesExist,
    void Function()? afterReset,
    BackgroundTurn? reattachTurn,
  }) async {
    _stashAndClearPendingDraftsForCurrentSession();
    _messages.clear();
    _clearStreamBuffers();
    _pendingQueue.clear();
    _historyLoading = true;
    final int loadSeq = ++_historyLoadSeq;
    _lastError = null;
    _isCancelling = false;
    _activeRequestId = null;
    _localStreamActive = false;
    _reattachRequestId = null;
    _foregroundTurn = null;
    _remoteActive = false;
    _remoteSettleTimer?.cancel();
    _stopHistoryPolling();
    notifyListeners();
    unawaited(refreshAuthStatus());
    afterReset?.call();
    try {
      final String sessionId = await _ensureActiveSessionId(agent);
      final List<ChatMessage>? history = await _fetchHistoryIfCurrent(
        agent,
        machine,
        sessionId,
      );
      if (history == null || (skipIfMessagesExist && _messages.isNotEmpty)) {
        return;
      }
      _applyHistorySnapshot(history);
      final bool restoredDrafts = _restorePendingDraftsFor(
        agent.key,
        sessionId,
      );
      if (reattachTurn != null) {
        _reattachBackgroundTurn(reattachTurn);
      } else if (isThinking) {
        _startHistoryPolling();
      }
      notifyListeners();
      if (restoredDrafts && !(isThinking || _remoteActive)) {
        unawaited(_maybeDrainQueue());
      }
    } catch (_) {
      // Leave the view empty when history can't be loaded.
    } finally {
      if (loadSeq == _historyLoadSeq) {
        _historyLoading = false;
        notifyListeners();
      }
    }
  }

  Future<FsListing> browseWorkdir(String path, {bool showHidden = false}) =>
      _backendClient.browseWorkdir(path, showHidden: showHidden);

  Future<FsDownloadStream> openFileDownload(String path) =>
      _backendClient.openFileDownload(path);

  Future<FsEntry> uploadFile({
    required String path,
    required String name,
    required Uint8List bytes,
  }) =>
      _backendClient.uploadFile(path: path, name: name, bytes: bytes);

  Future<FsEntry> uploadFileStream({
    required String path,
    required String name,
    required Stream<List<int>> bytes,
    required int length,
  }) =>
      _backendClient.uploadFileStream(
        path: path,
        name: name,
        bytes: bytes,
        length: length,
      );

  void connectEvents() {
    _wantsEvents = true;
    _connectEventsNow();
  }

  Future<void> reconnectEvents() async {
    _eventReconnectTimer?.cancel();
    await _eventsSub?.cancel();
    _eventsSub = null;
    if (_wantsEvents) _connectEventsNow();
  }

  Future<void> disposeController() async {
    _wantsEvents = false;
    _eventReconnectTimer?.cancel();
    _historyPollTimer?.cancel();
    _remoteSettleTimer?.cancel();
    _cancelStreamingNotifyTimer();
    _foregroundTurn?.detached = true;
    _foregroundTurn?.streamHandle.close();
    _clearBackgroundTurns();
    await _eventsSub?.cancel();
    await _backendClient.close();
  }

  void _restorePendingTurnFromHistory() {
    ChatMessage? pending;
    for (int i = _messages.length - 1; i >= 0; i -= 1) {
      final ChatMessage message = _messages[i];
      if (!message.isUser && message.metadata[_streamingKey] == true) {
        pending = message;
        break;
      }
    }

    final String requestId = pending?.metadata[_requestIdKey] as String? ?? '';
    if (pending != null && requestId.isNotEmpty) {
      _isCancelling = false;
      _activeRequestId = requestId;
      return;
    }
    _isCancelling = false;
    _activeRequestId = null;
  }

  // Fetch history, returning null if the context (agent/machine/session) drifted
  // while the request was in flight — callers must not apply a stale snapshot.
  // The session is owned by the host, so this is how the app pulls it back.
  Future<List<ChatMessage>?> _fetchHistoryIfCurrent(
    CliAgent agent,
    MachineCredential machine,
    String sessionId,
  ) async {
    final List<ChatMessage> history = await _backendClient.fetchHistory(
      agent.key,
      sessionId: sessionId,
    );
    if (_agent.key != agent.key ||
        _machine?.id != machine.id ||
        activeSessionId != sessionId) {
      return null;
    }
    return history;
  }

  // Replace the visible conversation with a freshly fetched snapshot and re-derive
  // any in-flight turn from it.
  void _applyHistorySnapshot(List<ChatMessage> history) {
    // Locally-queued follow-ups aren't in server history yet; keep them (at the
    // end, preserving order) so a snapshot refresh never drops pending input.
    final List<ChatMessage> pending = _pendingQueue.isEmpty
        ? const <ChatMessage>[]
        : _messages
            .where((ChatMessage m) => _pendingQueue.contains(m.id))
            .toList(growable: false);
    _messages
      ..clear()
      ..addAll(history)
      ..addAll(pending);
    _seedStreamBuffersFromMessages();
    _restorePendingTurnFromHistory();
  }

  bool _historySnapshotMatchesCurrent(List<ChatMessage> history) {
    if (history.length != _messages.length) return false;
    if (history.isEmpty) return true;
    final ChatMessage fetched = history.last;
    final ChatMessage current = _messages.last;
    return fetched.id == current.id &&
        fetched.content.length == current.content.length &&
        fetched.metadata[_streamingKey] == current.metadata[_streamingKey];
  }

  void _seedStreamBuffersFromMessages() {
    _streamBuffers.clear();
    _streamSegments.clear();
    for (final ChatMessage message in _messages) {
      if (message.isUser || message.metadata[_streamingKey] != true) continue;
      final String requestId = message.metadata[_requestIdKey] as String? ?? '';
      if (requestId.isEmpty) continue;
      _streamBuffers[requestId] = StringBuffer(message.content);
      final List<MessageSegment> seeded = message.segments;
      if (seeded.isNotEmpty) {
        _streamSegments[requestId] = seeded.map((MessageSegment s) {
          final _StreamSegment live =
              _StreamSegment(s.createdAt ?? message.createdAt);
          live.buffer.write(s.text);
          return live;
        }).toList();
      }
    }
  }

  void _clearStreamBuffers() {
    _streamBuffers.clear();
    _streamSegments.clear();
  }

  void _clearBackgroundTurns() {
    for (final BackgroundTurn turn in _backgroundTurns.list()) {
      turn.closeStream?.call();
    }
    _backgroundTurns.clear();
  }

  List<String> _pendingDraftTexts() {
    if (_pendingQueue.isEmpty) return const <String>[];
    final Map<String, ChatMessage> messagesById = <String, ChatMessage>{
      for (final ChatMessage message in _messages) message.id: message,
    };
    return _pendingQueue
        .map((String id) => messagesById[id]?.content ?? '')
        .where((String text) => text.trim().isNotEmpty)
        .toList(growable: false);
  }

  void _stashAndClearPendingDraftsForCurrentSession() {
    final String? sessionId = activeSessionId;
    final List<String> drafts = _pendingDraftTexts();
    if (sessionId != null && sessionId.isNotEmpty && drafts.isNotEmpty) {
      _pendingDrafts.stash(_agent.key, sessionId, drafts);
    }
    if (_pendingQueue.isEmpty) return;
    final Set<String> queuedIds = _pendingQueue.toSet();
    _messages.removeWhere(
      (ChatMessage message) =>
          queuedIds.contains(message.id) &&
          message.metadata[_queuedKey] == true,
    );
    _pendingQueue.clear();
  }

  bool _restorePendingDraftsFor(String agentKey, String sessionId) {
    final List<String> drafts = _pendingDrafts.take(agentKey, sessionId);
    if (drafts.isEmpty) return false;
    for (final String draft in drafts) {
      final ChatMessage message = ChatMessage.user(draft);
      _messages.add(
        message.copyWith(metadata: <String, Object?>{_queuedKey: true}),
      );
      _pendingQueue.add(message.id);
    }
    return true;
  }

  String? _lastStreamingRequestId() {
    for (int i = _messages.length - 1; i >= 0; i -= 1) {
      final ChatMessage message = _messages[i];
      if (message.isUser || message.metadata[_streamingKey] != true) {
        continue;
      }
      final String requestId = message.metadata[_requestIdKey] as String? ?? '';
      if (requestId.isNotEmpty) return requestId;
    }
    return null;
  }

  BackgroundTurn? _takeBackgroundTurn(String agentKey, String sessionId) =>
      _backgroundTurns.take(agentKey, sessionId);

  void _clearVisibleTurnStateForContextSwitch() {
    _activeRequestId = null;
    _localStreamActive = false;
    _isCancelling = false;
    _reattachRequestId = null;
    _remoteActive = false;
    _foregroundTurn = null;
    _remoteSettleTimer?.cancel();
    _stopHistoryPolling();
    _cancelStreamingNotifyTimer();
  }

  void _detachVisibleTurnForContextSwitch() {
    _stashAndClearPendingDraftsForCurrentSession();
    if (!(isThinking || _remoteActive || _localStreamActive)) return;
    final _ForegroundTurn? foreground = _foregroundTurn;
    final String requestId = foreground?.requestId ??
        _activeRequestId ??
        _reattachRequestId ??
        _lastStreamingRequestId() ??
        '';
    final String agentKey = foreground?.agentKey ?? _agent.key;
    final String sessionId = foreground?.sessionId ?? activeSessionId ?? '';
    foreground?.detached = true;
    if (foreground != null && !foreground.started) {
      foreground.streamHandle.close();
      _clearVisibleTurnStateForContextSwitch();
      notifyListeners();
      return;
    }
    if (requestId.isEmpty || sessionId.isEmpty) {
      _clearVisibleTurnStateForContextSwitch();
      notifyListeners();
      return;
    }

    final BackgroundTurn turn = BackgroundTurn(
      requestId: requestId,
      agentKey: agentKey,
      agentLabel: foreground?.agentLabel ?? _agentLabelFor(agentKey),
      sessionId: sessionId,
      sessionName:
          foreground?.sessionName ?? _sessionNameFor(agentKey, sessionId),
      closeStream: foreground?.streamHandle.close,
    );
    _backgroundTurns.add(turn, started: foreground?.started ?? true);
    _clearVisibleTurnStateForContextSwitch();
    turn.closeStream?.call();
    notifyListeners();
  }

  void _reattachBackgroundTurn(BackgroundTurn turn) {
    turn.closeStream?.call();
    _reattachRequestId = turn.requestId;
    _remoteSettleTimer?.cancel();
    _remoteActive = true;
    _startHistoryPolling();
    unawaited(_refreshHistorySnapshot());
  }

  void _startHistoryPolling() {
    if (_historyPollTimer != null) return;
    _historyPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshHistorySnapshot()),
    );
  }

  void _stopHistoryPolling() {
    _historyPollTimer?.cancel();
    _historyPollTimer = null;
  }

  bool _finishReattachIfNotStreaming(List<ChatMessage> history) {
    final String? reattachId = _reattachRequestId;
    if (reattachId == null) return false;
    for (final ChatMessage message in history) {
      if (message.isUser) continue;
      if (message.metadata[_requestIdKey] != reattachId) continue;
      if (message.metadata[_streamingKey] == true) return false;
      break;
    }
    _reattachRequestId = null;
    _remoteSettleTimer?.cancel();
    _remoteActive = false;
    if (!isThinking) _stopHistoryPolling();
    unawaited(_maybeDrainQueue());
    return true;
  }

  Future<void> _refreshHistorySnapshot() async {
    final MachineCredential? machine = _machine;
    if (!(isThinking || _remoteActive) || machine == null) {
      _stopHistoryPolling();
      return;
    }
    final CliAgent agent = _agent;
    final String? sessionId = activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    try {
      final List<ChatMessage>? history = await _fetchHistoryIfCurrent(
        agent,
        machine,
        sessionId,
      );
      if (history == null) return;
      // Never clobber a turn our own POST stream is actively driving (that
      // stream is the smoother, authoritative source). Once it drops or is
      // absent (reattach / cold-start restore), polling becomes authoritative.
      if (_localStreamActive) return;
      final bool matchesCurrent = _historySnapshotMatchesCurrent(history);
      if (!matchesCurrent) _applyHistorySnapshot(history);
      final bool reattachFinished = _finishReattachIfNotStreaming(history);
      if (matchesCurrent) {
        if (!(isThinking || _remoteActive)) _stopHistoryPolling();
        if (reattachFinished) notifyListeners();
        return;
      }
      if (!(isThinking || _remoteActive)) _stopHistoryPolling();
      notifyListeners();
    } catch (_) {
      // Keep the last visible snapshot; the next poll/event may recover.
    }
  }

  // A turn started by another device on the conversation we are viewing. Mirror
  // it from persisted history. Skip while we have our own turn in flight; we do
  // a catch-up refresh when ours finishes.
  void _beginRemoteMirror() {
    if (isThinking) return;
    _remoteSettleTimer?.cancel();
    _remoteActive = true;
    _startHistoryPolling();
    unawaited(_refreshHistorySnapshot());
  }

  // A remote turn finished. Do a final refresh shortly after so the snapshot
  // captures the finalized (non-streaming) message, then stop mirroring.
  void _endRemoteMirror() {
    if (!_remoteActive) return;
    unawaited(_refreshHistorySnapshot());
    _remoteSettleTimer?.cancel();
    _remoteSettleTimer = Timer(const Duration(milliseconds: 900), () {
      _remoteActive = false;
      unawaited(_refreshHistorySnapshot());
      if (!isThinking) _stopHistoryPolling();
      // A turn we were only mirroring (e.g. a reattached one) just finished;
      // release any follow-ups queued while it ran.
      unawaited(_maybeDrainQueue());
    });
  }

  Future<void> _runTurn(CliAgent agent, ChatMessage userMessage) async {
    _isCancelling = false;
    _localStreamActive = false;
    _lastError = null;
    final String requestId = _newRequestId(agent);
    final ChatStreamHandle streamHandle = ChatStreamHandle();
    final String initialSessionId = activeSessionId ?? '';
    final _ForegroundTurn turn = _ForegroundTurn(
      requestId: requestId,
      agentKey: agent.key,
      agentLabel: agent.label,
      sessionId: initialSessionId,
      sessionName: initialSessionId.isEmpty
          ? ''
          : _sessionNameFor(agent.key, initialSessionId),
      streamHandle: streamHandle,
    );
    _foregroundTurn = turn;
    _activeRequestId = requestId;
    notifyListeners();

    bool reattach = false;
    try {
      final String sessionId = await _ensureActiveSessionId(agent);
      turn.sessionId = sessionId;
      turn.sessionName = _sessionNameFor(agent.key, sessionId);
      if (turn.detached || !identical(_foregroundTurn, turn)) return;
      _insertAwaitingAssistant(requestId: requestId);
      final ChatReply reply = await _backendClient.sendMessage(
        agentKey: agent.key,
        sessionId: sessionId,
        prompt: userMessage.content,
        requestId: requestId,
        streamHandle: streamHandle,
        onStreamStarted: () {
          if (turn.detached || !identical(_foregroundTurn, turn)) return;
          turn.started = true;
          _localStreamActive = true;
        },
        onEvent: (BackendEvent event) {
          if (turn.detached || !identical(_foregroundTurn, turn)) return;
          _handleEvent(event);
        },
      );
      if (turn.detached || !identical(_foregroundTurn, turn)) return;
      final List<Map<String, Object?>> replySegments = reply.segments
          .map(
            (MessageSegment s) => <String, Object?>{
              if (s.createdAt != null)
                'ts': s.createdAt!.toUtc().toIso8601String(),
              'text': s.text,
            },
          )
          .toList(growable: false);
      _finalizeAssistantByRequestId(
        requestId,
        reply.content,
        metadata: <String, Object?>{
          _requestIdKey: reply.requestId,
          'agentKey': reply.agentKey,
          'agentLabel': reply.agentLabel,
          if (replySegments.isNotEmpty) _segmentsKey: replySegments,
        },
      );
    } catch (err) {
      if (turn.detached || !identical(_foregroundTurn, turn)) return;
      if (err is BackendException && err.code == 'AGENT_CANCELLED') {
        _markAssistantCancelled(requestId);
      } else if (_isStreamDisconnect(err)) {
        // The stream dropped (app backgrounded/closed, flaky network) but the
        // backend keeps running this turn. Keep the streaming placeholder and
        // the user message as-is; hand off to history polling + the shared
        // event stream, which mirror progress and finalize when it completes.
        reattach = true;
      } else {
        _discardAssistantByRequestId(requestId);
        String detail = _friendlyError(err);
        if (err is BackendException && err.code == 'AGENT_BUSY') {
          detail = _strings.agentBusyRetryLater;
        } else if (err is BackendException && err.code == 'NOT_LOGGED_IN') {
          detail = _strings.agentNotLoggedIn(agent.label);
          // Reflect the failure in the banner right away.
          _authStatus[agent.key] = false;
        }
        _markUserDeliveryFailed(userMessage.id, detail);
        _lastError = detail;
      }
    } finally {
      final bool ownsForeground = identical(_foregroundTurn, turn);
      if (ownsForeground) {
        if (_activeRequestId == requestId) _activeRequestId = null;
        _localStreamActive = false;
        _isCancelling = false;
        _foregroundTurn = null;
      }
      if (ownsForeground || turn.detached) streamHandle.close();
      if (reattach && ownsForeground && !turn.detached) {
        // Resume mirroring this still-running turn from shared state. Tracking
        // the requestId lets polling end the mirror once it finalizes.
        _reattachRequestId = requestId;
        _beginRemoteMirror();
      }
      if (ownsForeground) notifyListeners();
      // A remote turn may have started and finished on this scope while ours was
      // in flight (we skip mirroring then). Catch up to the shared truth now.
      if (!reattach && ownsForeground && !turn.detached) {
        unawaited(_catchUpHistory());
        // The conversation is free again: send the next queued follow-up. (A
        // reattached turn is still running, so its queue drains when it ends.)
        unawaited(_maybeDrainQueue());
      }
    }
  }

  // True when a send failed because the stream/connection dropped rather than
  // because the agent reported a terminal result. The backend turn may still be
  // running, so the caller should reattach instead of failing the turn.
  bool _isStreamDisconnect(Object err) {
    if (err is TimeoutException) return true;
    if (err is BackendException) {
      final String? code = err.code;
      if (code == 'STREAM_DISCONNECTED' || code == 'STREAM_INCOMPLETE') {
        return true;
      }
      if (code != null && code.startsWith('NETWORK_')) return true;
    }
    return false;
  }

  // One-shot pull of the shared history, used after our own turn ends to pick up
  // any changes other devices made meanwhile. No-op if a new turn is running.
  Future<void> _catchUpHistory() async {
    final MachineCredential? machine = _machine;
    if (isThinking || _remoteActive || machine == null) return;
    final CliAgent agent = _agent;
    final String? sessionId = activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    try {
      final List<ChatMessage>? history = await _fetchHistoryIfCurrent(
        agent,
        machine,
        sessionId,
      );
      // Bail if our own or a remote turn started while the fetch was in flight.
      if (history == null || isThinking || _remoteActive || history.isEmpty) {
        return;
      }
      _applyHistorySnapshot(history);
      // The snapshot may have adopted a still-streaming turn another device
      // started while ours was running; if so, poll it to completion (nothing
      // else will — _beginRemoteMirror no-ops once isThinking is true).
      if (isThinking) _startHistoryPolling();
      notifyListeners();
    } catch (_) {
      // Best-effort; the next interaction will reconcile.
    }
  }

  int _insertAwaitingAssistant({bool system = false, String? requestId}) {
    _messages.add(
      ChatMessage.assistant(
        '',
        metadata: <String, Object?>{
          _streamingKey: true,
          _awaitingFirstTokenKey: true,
          if (requestId != null) _requestIdKey: requestId,
          if (system) _systemKey: true,
        },
      ),
    );
    notifyListeners();
    return _messages.length - 1;
  }

  void _setStreamingAssistantContent(
    int assistantIndex, {
    required String content,
    required bool awaitingFirstToken,
    List<Map<String, Object?>>? segments,
  }) {
    if (assistantIndex >= _messages.length) return;
    _messages[assistantIndex] = _messages[assistantIndex].copyWith(
      content: content,
      metadata: <String, Object?>{
        ..._messages[assistantIndex].metadata,
        _streamingKey: true,
        _awaitingFirstTokenKey: awaitingFirstToken,
        if (segments != null) _segmentsKey: segments,
      },
    );
  }

  // Serialize the live segments for a request into the metadata shape the UI and
  // the backend share: a list of { ts, text }.
  List<Map<String, Object?>> _serializeStreamSegments(String requestId) {
    final List<_StreamSegment>? segments = _streamSegments[requestId];
    if (segments == null || segments.isEmpty) {
      return const <Map<String, Object?>>[];
    }
    return segments
        .map(
          (_StreamSegment s) => <String, Object?>{
            'ts': s.createdAt.toIso8601String(),
            'text': s.buffer.toString(),
          },
        )
        .toList(growable: false);
  }

  void _flushStreamBuffer(String requestId) {
    final StringBuffer? buffer = _streamBuffers[requestId];
    if (buffer == null) return;
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    final ChatMessage message = _messages[index];
    if (isCancelled(message) || message.metadata[_streamingKey] != true) {
      return;
    }
    final String content = buffer.toString();
    if (message.content == content &&
        message.metadata[_awaitingFirstTokenKey] == false) {
      return;
    }
    final List<Map<String, Object?>> segments =
        _serializeStreamSegments(requestId);
    _setStreamingAssistantContent(
      index,
      content: content,
      awaitingFirstToken: false,
      segments: segments.isEmpty ? null : segments,
    );
  }

  void _flushStreamBuffers() {
    for (final String requestId in List<String>.of(_streamBuffers.keys)) {
      _flushStreamBuffer(requestId);
    }
  }

  void _finalizeAssistant(
    int assistantIndex,
    String text, {
    bool system = false,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    _cancelStreamingNotifyTimer();
    final Map<String, Object?> finalMetadata = <String, Object?>{
      _streamingKey: false,
      _awaitingFirstTokenKey: false,
      if (system) _systemKey: true,
      ...metadata,
    };
    if (assistantIndex >= _messages.length) {
      _messages.add(ChatMessage.assistant(text, metadata: finalMetadata));
      notifyListeners();
      return;
    }
    _messages[assistantIndex] = _messages[assistantIndex].copyWith(
      content: text,
      metadata: finalMetadata,
    );
    notifyListeners();
  }

  void _finalizeAssistantByRequestId(
    String requestId,
    String text, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    // _finalizeAssistant replaces metadata wholesale, so carry the segments
    // forward: prefer the authoritative ones from the reply, else keep what
    // streamed (covers older backends that don't return segments).
    final Object? existingSegments = _messages[index].metadata[_segmentsKey];
    _streamBuffers.remove(requestId);
    _streamSegments.remove(requestId);
    final String metadataRequestId = metadata[_requestIdKey] as String? ?? '';
    if (metadataRequestId.isNotEmpty && metadataRequestId != requestId) {
      _streamBuffers.remove(metadataRequestId);
      _streamSegments.remove(metadataRequestId);
    }
    _finalizeAssistant(
      index,
      text,
      metadata: <String, Object?>{
        if (existingSegments != null) _segmentsKey: existingSegments,
        _requestIdKey: requestId,
        ...metadata,
      },
    );
  }

  void _discardAssistant(int assistantIndex) {
    if (assistantIndex >= _messages.length) return;
    _cancelStreamingNotifyTimer();
    final String requestId =
        _messages[assistantIndex].metadata[_requestIdKey] as String? ?? '';
    if (requestId.isNotEmpty) {
      _streamBuffers.remove(requestId);
      _streamSegments.remove(requestId);
    }
    _messages.removeAt(assistantIndex);
    notifyListeners();
  }

  void _discardAssistantByRequestId(String requestId) {
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    _discardAssistant(index);
  }

  void _appendDelta(Map<String, Object?> data) {
    final String requestId = data['requestId'] as String? ?? '';
    final String text = data['text'] as String? ?? '';
    if (requestId.isEmpty || text.isEmpty) return;

    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    final ChatMessage current = _messages[index];
    // Append only while the bubble is still streaming. Once the POST response
    // finalizes the authoritative answer, late SSE deltas must be ignored.
    if (isCancelled(current) || current.metadata[_streamingKey] != true) return;

    final StringBuffer buffer = _streamBuffers.putIfAbsent(
      requestId,
      () => StringBuffer(current.content),
    );
    buffer.write(text);
    // Append to the open segment, opening the first one on the first delta (the
    // backend only emits an explicit boundary for the 2nd+ message in a turn).
    final List<_StreamSegment> segments = _streamSegments.putIfAbsent(
      requestId,
      () => <_StreamSegment>[_StreamSegment(DateTime.now())],
    );
    if (segments.isEmpty) segments.add(_StreamSegment(DateTime.now()));
    segments.last.buffer.write(text);
    if (current.metadata[_awaitingFirstTokenKey] == true) {
      _messages[index] = current.copyWith(
        metadata: <String, Object?>{
          ...current.metadata,
          _streamingKey: true,
          _awaitingFirstTokenKey: false,
        },
      );
    }
    _notifyStreamingUpdate();
  }

  // The agent started a new follow-up message in the same turn. Open a fresh
  // segment and separate it from the previous one in the flat buffer.
  void _appendSegmentBoundary(String requestId) {
    if (requestId.isEmpty) return;
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    final ChatMessage current = _messages[index];
    if (isCancelled(current) || current.metadata[_streamingKey] != true) return;
    final StringBuffer buffer = _streamBuffers.putIfAbsent(
      requestId,
      () => StringBuffer(current.content),
    );
    if (buffer.isNotEmpty) buffer.write('\n\n');
    _streamSegments
        .putIfAbsent(requestId, () => <_StreamSegment>[])
        .add(_StreamSegment(DateTime.now()));
    _notifyStreamingUpdate();
  }

  void _markAssistantCancelled(String requestId) {
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    _flushStreamBuffer(requestId);
    _streamBuffers.remove(requestId);
    _streamSegments.remove(requestId);
    _cancelStreamingNotifyTimer();
    final ChatMessage message = _messages[index];
    _messages[index] = message.copyWith(
      content: message.content,
      metadata: <String, Object?>{
        ...message.metadata,
        _streamingKey: false,
        _awaitingFirstTokenKey: false,
        _cancelledKey: true,
      },
    );
    notifyListeners();
  }

  void _notifyStreamingUpdate() {
    if (_streamNotifyTimer != null) {
      _streamNotifyQueued = true;
      return;
    }
    _flushStreamBuffers();
    notifyListeners();
    _streamNotifyTimer = Timer(const Duration(milliseconds: 80), () {
      _streamNotifyTimer = null;
      if (!_streamNotifyQueued) return;
      _streamNotifyQueued = false;
      _notifyStreamingUpdate();
    });
  }

  void _cancelStreamingNotifyTimer() {
    _streamNotifyTimer?.cancel();
    _streamNotifyTimer = null;
    _streamNotifyQueued = false;
  }

  int _assistantIndexForRequest(String requestId) {
    if (requestId.isEmpty) return -1;
    for (int i = _messages.length - 1; i >= 0; i -= 1) {
      final ChatMessage message = _messages[i];
      if (!message.isUser && message.metadata[_requestIdKey] == requestId) {
        return i;
      }
    }
    return -1;
  }

  // Turn a thrown error into a message a user can act on. Low-level network
  // failures (BackendException with a NETWORK_* code) become localized guidance;
  // other backend errors show their server message without the wrapper prefix.
  String _friendlyError(Object err) => friendlyErrorText(_strings, err);

  void _markUserDeliveryFailed(String localId, String detail) {
    final int index = _messages.indexWhere((ChatMessage m) => m.id == localId);
    if (index == -1) return;
    _messages[index] = _messages[index].copyWith(
      metadata: <String, Object?>{
        ..._messages[index].metadata,
        _deliveryFailedKey: true,
        _errorDetailKey: detail,
      },
    );
    notifyListeners();
  }

  // Append a centered, non-bubble status line to the current conversation.
  void appendNotice(String text) {
    _messages.add(
      ChatMessage.assistant(
        text,
        metadata: const <String, Object?>{_noticeKey: true},
      ),
    );
    notifyListeners();
  }

  void _appendSystemMessage(String text) {
    _messages.add(
      ChatMessage.assistant(
        text,
        metadata: const <String, Object?>{_systemKey: true},
      ),
    );
    notifyListeners();
  }

  String _newRequestId(CliAgent agent) {
    final int micros = DateTime.now().microsecondsSinceEpoch;
    return '${agent.key}.$micros';
  }

  void _connectEventsNow() {
    if (!_wantsEvents || _eventsSub != null) return;
    _eventsSub = _backendClient.streamEvents().listen(
      _handleScopeEvent,
      onError: (Object error) {
        _eventsSub = null;
        _scheduleEventReconnect();
      },
      onDone: () {
        _eventsSub = null;
        _scheduleEventReconnect();
      },
      cancelOnError: true,
    );
  }

  void _scheduleEventReconnect() {
    if (!_wantsEvents || _eventReconnectTimer != null) return;
    _eventReconnectTimer = Timer(const Duration(seconds: 15), () {
      _eventReconnectTimer = null;
      _connectEventsNow();
    });
  }

  // Events for our own in-flight turn, delivered on the chat POST stream.
  void _handleEvent(BackendEvent event) {
    switch (event.type) {
      case 'agent_delta':
        _appendDelta(event.data);
        return;
      case 'agent_segment':
        _appendSegmentBoundary(event.data['requestId'] as String? ?? '');
        return;
      case 'agent_progress':
        _appendProgress(event.data);
        return;
      case 'agent_queued':
        final String requestId = event.data['requestId'] as String? ?? '';
        if (requestId.isNotEmpty) {
          _appendProgress(<String, Object?>{
            'requestId': requestId,
            'line': _strings.agentQueued,
          });
        }
        return;
      case 'agent_cancelled':
        final String requestId = event.data['requestId'] as String? ?? '';
        if (requestId.isNotEmpty) {
          _markAssistantCancelled(requestId);
        }
        return;
      case 'agent_error':
        final String requestId = event.data['requestId'] as String? ?? '';
        final String error = event.data['error'] as String? ?? '';
        if (requestId.isNotEmpty && error.isNotEmpty) {
          _appendProgress(<String, Object?>{
            'requestId': requestId,
            'line': _strings.agentErrorLine(error),
          });
        }
        return;
    }
  }

  bool _isTurnProgressEvent(String type) {
    switch (type) {
      case 'agent_start':
      case 'agent_queued':
      case 'agent_delta':
      case 'agent_segment':
      case 'agent_progress':
        return true;
    }
    return false;
  }

  bool _isTurnTerminalEvent(String type) {
    switch (type) {
      case 'agent_done':
      case 'agent_cancelled':
      case 'agent_error':
        return true;
    }
    return false;
  }

  void _upsertBackgroundTurn({
    required String requestId,
    required String agentKey,
    required String agentLabel,
    required String sessionId,
    required String sessionName,
  }) {
    final BackgroundTurn? existing = _backgroundTurns.get(
      agentKey,
      sessionId,
    );
    if (existing != null && existing.requestId == requestId) return;
    _backgroundTurns.add(
      BackgroundTurn(
        requestId: requestId,
        agentKey: agentKey,
        agentLabel: agentLabel,
        sessionId: sessionId,
        sessionName: sessionName,
      ),
    );
    notifyListeners();
  }

  void _completeBackgroundTurn(String agentKey, String sessionId) {
    final BackgroundTurn? turn = _backgroundTurns.complete(
      agentKey,
      sessionId,
    );
    if (turn == null) return;
    turn.closeStream?.call();
    notifyListeners();
    unawaited(_showBackgroundTurnNotification(turn));
  }

  // Events on the shared event stream, scoped by the backend to our current
  // work directory. Drives quota alerts and cross-device mirroring: a turn
  // started on another device in the same path is mirrored here from history.
  void _handleScopeEvent(BackendEvent event) {
    if (event.type == 'quota_reset') {
      final String message = _strings.isZh
          ? event.data['messageZh'] as String? ??
              event.data['message'] as String? ??
              ''
          : event.data['message'] as String? ?? '';
      if (message.isEmpty) return;
      // Quota alerts prefer a system/browser notification. If the platform
      // denies it, fall back to an in-page system message for Web users.
      unawaited(_showQuotaNotification(message));
      return;
    }
    if (event.type == 'quota_schedule_sent' ||
        event.type == 'quota_schedule_failed') {
      _quotaScheduleRevision += 1;
      notifyListeners();
      final String message = _strings.isZh
          ? event.data['messageZh'] as String? ??
              event.data['message'] as String? ??
              ''
          : event.data['message'] as String? ?? '';
      if (message.isEmpty) return;
      unawaited(_showQuotaNotification(message));
      return;
    }
    if (event.type == 'quota_schedule_changed') {
      _quotaScheduleRevision += 1;
      notifyListeners();
      return;
    }

    final String requestId = event.data['requestId'] as String? ?? '';
    if (requestId.isEmpty) return;
    if (_machine == null) return;
    final Map<String, Object?> agentData =
        (event.data['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final String agentKey = agentData['key'] as String? ?? '';
    final String agentLabel =
        agentData['label'] as String? ?? _agentLabelFor(agentKey);
    final Map<String, Object?> sessionData =
        (event.data['session'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final String sessionId = sessionData['id'] as String? ?? '';
    final String sessionName =
        sessionData['name'] as String? ?? _sessionNameFor(agentKey, sessionId);
    final bool exactSession = agentKey.isNotEmpty && sessionId.isNotEmpty;
    final String? active = activeSessionId;
    final bool activeSessionEvent =
        (agentKey.isEmpty || agentKey == _agent.key) &&
            (sessionId.isEmpty ||
                active == null ||
                active.isEmpty ||
                sessionId == active);

    if (exactSession && !activeSessionEvent) {
      if (_isTurnTerminalEvent(event.type)) {
        _completeBackgroundTurn(agentKey, sessionId);
        return;
      }
      if (_isTurnProgressEvent(event.type)) {
        _upsertBackgroundTurn(
          requestId: requestId,
          agentKey: agentKey,
          agentLabel: agentLabel,
          sessionId: sessionId,
          sessionName: sessionName,
        );
        return;
      }
      return;
    }

    // Ignore the echo of our own turn only while our POST stream is actively
    // driving it. If that stream dropped, these shared events are how we learn
    // the still-running turn progressed and finished.
    if (requestId == _activeRequestId && _localStreamActive) return;
    // Only mirror activity for the agent we are currently viewing.
    if (agentKey.isNotEmpty && agentKey != _agent.key) return;
    // Only drop an event when we actually know which session we're viewing.
    // While sessions are still loading (activeSessionId == null) we let events
    // through; the history poll then reconciles against the correct session.
    if (sessionId.isNotEmpty &&
        active != null &&
        active.isNotEmpty &&
        sessionId != active) {
      return;
    }

    switch (event.type) {
      case 'agent_start':
      case 'agent_queued':
      case 'agent_delta':
      case 'agent_segment':
      case 'agent_progress':
        _beginRemoteMirror();
        return;
      case 'agent_done':
      case 'agent_cancelled':
      case 'agent_error':
        _endRemoteMirror();
        return;
    }
  }

  Future<void> _showQuotaNotification(String message) async {
    // The backend sends every quota alert twice on purpose: once down the event
    // stream for open sessions, and once as a push for closed ones. On the web
    // the push service worker shows its copy whether or not the tab is focused,
    // so a browser this backend can actually push to must not also show the
    // event-stream copy — that is the duplicate.
    if (_webPushDelivers(quota: true)) return;
    await _showNotificationOrSystemMessage(message, tag: 'quota');
  }

  Future<void> _showBackgroundTurnNotification(BackgroundTurn turn) async {
    if (_webPushDelivers(quota: false)) return;
    await _showNotificationOrSystemMessage(
      _strings.backgroundSessionFinished(turn.agentLabel, turn.sessionName),
      tag: 'task:${turn.agentKey}:${turn.sessionId}',
    );
  }

  /// Whether this browser's push subscription will already deliver an alert of
  /// this category, making an in-page notification a duplicate. False off the
  /// web, and false until a subscription is actually registered — a backend
  /// with no VAPID keys never pushes, so the in-page copy stays the only one.
  bool _webPushDelivers({required bool quota}) {
    if (!kIsWeb || !_webPushActive) return false;
    return quota ? _quotaPushEnabled : _taskPushEnabled;
  }

  Future<void> _showNotificationOrSystemMessage(
    String message, {
    String? tag,
  }) async {
    try {
      final bool shown = await NotificationService.instance.show(
        title: 'Relay',
        body: message,
        tag: tag,
      );
      if (!shown) _appendSystemMessage(message);
    } catch (_) {
      _appendSystemMessage(message);
    }
  }

  void _appendProgress(Map<String, Object?> data) {
    final String requestId = data['requestId'] as String? ?? '';
    final String line = data['line'] as String? ?? '';
    if (requestId.isEmpty || line.isEmpty) return;

    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;

    final List<String> lines = progressLinesFor(
      _messages[index],
    ).toList(growable: true);
    if (lines.isEmpty || lines.last != line) lines.add(line);
    while (lines.length > 6) {
      lines.removeAt(0);
    }

    _messages[index] = _messages[index].copyWith(
      metadata: <String, Object?>{
        ..._messages[index].metadata,
        _progressLinesKey: List<String>.unmodifiable(lines),
      },
    );
    notifyListeners();
  }
}

/// A live, in-progress assistant segment held while a turn streams. Serialized
/// into the message's `metadata['segments']` so the bubble can show each
/// follow-up message with its own arrival time.
class _StreamSegment {
  _StreamSegment(this.createdAt);

  final DateTime createdAt;
  final StringBuffer buffer = StringBuffer();
}

class _ForegroundTurn {
  _ForegroundTurn({
    required this.requestId,
    required this.agentKey,
    required this.agentLabel,
    required this.sessionId,
    required this.sessionName,
    required this.streamHandle,
  });

  final String requestId;
  final String agentKey;
  final String agentLabel;
  String sessionId;
  String sessionName;
  final ChatStreamHandle streamHandle;
  bool detached = false;
  bool started = false;
}
