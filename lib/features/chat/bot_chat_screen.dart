// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/backend/backend_client.dart';
import '../../core/models/agent_session.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/group.dart';
import '../../core/models/machine_credential.dart';
import '../../core/platform/file_saver.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/time_format.dart';
import '../cli_agents/agent_status_lights.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../cli_agents/cli_agents_drawer.dart';
import '../machines/machine_credentials_controller.dart';
import '../machines/machine_credentials_screen.dart';
import '../settings/getting_started_screen.dart';
import 'agent_controls.dart';
import 'bot_chat_controller.dart';
import 'btw_dialog.dart';
import 'chat_content.dart';
import 'group_chat_screen.dart';

class BotChatScreen extends StatefulWidget {
  const BotChatScreen({
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
    required this.settingsController,
    super.key,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;
  final AppSettingsController settingsController;

  @override
  State<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends State<BotChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  bool _autoScrollQueued = false;
  int _lastMessageCount = 0;
  bool _agentsSynced = false;
  bool _agentsRefreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.chatController.addListener(_onChatChanged);
    widget.agentsController.addListener(_onContextChanged);
    widget.machinesController.addListener(_onContextChanged);
    widget.settingsController.addListener(_onSettingsChanged);
    _syncContext();
    // Open straight at the latest message rather than the top of the list.
    _onChatChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Coming back to the foreground, the OS may have torn down the long-lived
    // event SSE while the backend kept running a turn. Reconnect it right away
    // so a turn that continued in the background is mirrored without waiting for
    // the periodic reconnect.
    if (state == AppLifecycleState.resumed) {
      widget.chatController.reconnectEvents();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.chatController.removeListener(_onChatChanged);
    widget.agentsController.removeListener(_onContextChanged);
    widget.machinesController.removeListener(_onContextChanged);
    widget.settingsController.removeListener(_onSettingsChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onContextChanged() {
    _syncContext();
  }

  Future<void> _refreshAgents() async {
    // Rapid context syncs can call this before the first fetch resolves; one
    // in-flight request at a time is enough.
    if (_agentsRefreshing) return;
    _agentsRefreshing = true;
    try {
      final List<CliAgent> agents = await widget.chatController.backend
          .fetchAgents();
      if (!mounted) return;
      widget.agentsController.syncAgents(agents);
      _agentsSynced = true;
    } catch (_) {
      // Best-effort: keep the built-in list and retry on the next context sync.
    } finally {
      _agentsRefreshing = false;
    }
  }

  void _onSettingsChanged() {
    widget.chatController.setLanguage(widget.settingsController.language);
    widget.chatController.setNotificationPreferences(
      quotaPushEnabled: widget.settingsController.quotaPushEnabled,
      taskPushEnabled: widget.settingsController.taskPushEnabled,
    );
    widget.chatController.syncPushSubscription(force: true);
    widget.chatController.syncFcmRegistration(force: true);
  }

  void _syncContext() {
    widget.chatController.setLanguage(widget.settingsController.language);
    widget.chatController.setNotificationPreferences(
      quotaPushEnabled: widget.settingsController.quotaPushEnabled,
      taskPushEnabled: widget.settingsController.taskPushEnabled,
    );
    final CliAgent active = widget.agentsController.activeAgent;
    final MachineCredential? machine = widget.machinesController.activeMachine;
    if (machine == null) return;
    // Pull the host's live agent list and install/auth status. Retries until it
    // lands.
    if (!_agentsSynced) unawaited(_refreshAgents());
    if (!isCliAgentSelectable(active)) {
      if (widget.chatController.machine != null) {
        widget.chatController.goHome();
      }
      return;
    }
    if (widget.chatController.machine == null) return;
    final bool hadMachine = widget.chatController.machine != null;
    final bool machineChanged = widget.chatController.machine?.id != machine.id;
    if (widget.chatController.agent.key != active.key || machineChanged) {
      widget.chatController.loadFor(active, machine);
    }
    if (hadMachine && machineChanged) {
      widget.chatController.reconnectEvents();
    } else {
      widget.chatController.connectEvents();
    }
    // Register for Web Push so quota alerts arrive with the tab closed (web-only,
    // best-effort, runs once). Permission was already requested at startup.
    widget.chatController.syncPushSubscription();
    // Register for FCM on mobile. Missing Firebase config is a graceful no-op.
    widget.chatController.syncFcmRegistration();
  }

  Future<void> _send() async {
    final String text = _input.text;
    _input.clear();
    await widget.chatController.sendUserText(text);
  }

  Future<void> _sendCompact() async {
    final String compactedNotice = context.l10n.conversationCompacted;
    try {
      await widget.chatController.compressConversation();
      widget.chatController.appendNotice(compactedNotice);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(context.l10n.compressComplete),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(context.l10n.ok),
            ),
          ],
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.compressFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  // A streaming reply notifies many times per second. Calling animateTo on each
  // notification restarts the animation every frame, which is the main source
  // of scroll jank (and it gets worse as the list grows). Instead, coalesce to
  // at most one scroll per frame, jump rather than animate so nothing competes,
  // and leave the user alone when they have scrolled up to read older messages.
  //
  // The list is reverse:true, so the bottom (newest message) is offset 0
  // (minScrollExtent) and scrolling up to older messages increases the offset.
  void _onChatChanged() {
    if (_autoScrollQueued) return;
    _autoScrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollQueued = false;
      if (!_scroll.hasClients) return;
      final ScrollPosition pos = _scroll.position;
      final int count = widget.chatController.messageCount;
      final bool messageAdded = count != _lastMessageCount;
      _lastMessageCount = count;
      final bool nearBottom = pos.pixels - pos.minScrollExtent < 280;
      // Follow streaming text only while pinned to the bottom; always snap when
      // a new message (user send / new reply bubble) is appended.
      if (!nearBottom && !messageAdded) return;
      _scroll.jumpTo(pos.minScrollExtent);
    });
  }

  Future<void> _confirmClearHistory() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.clearChatTitle),
        content: Text(context.l10n.clearChatBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.clear),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.chatController.clearHistory();
    }
  }

  Future<void> _showHistorySearch() async {
    final ChatHistorySearchResult? result =
        await showDialog<ChatHistorySearchResult>(
          context: context,
          builder: (BuildContext dialogContext) =>
              _HistorySearchDialog(chatController: widget.chatController),
        );
    if (result == null) return;
    try {
      await widget.chatController.selectSession(
        cliAgentByKey(result.agentKey),
        result.sessionId,
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.searchFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _showBtw() async {
    final CliAgent agent = widget.agentsController.activeAgent;
    const Set<String> btwAgents = <String>{'claude', 'codex'};
    if (!btwAgents.contains(agent.key)) return;
    final String? sessionId = widget.chatController.activeSessionId;
    if (widget.chatController.messageCount == 0 ||
        sessionId == null ||
        sessionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.btwNeedsConversation)),
      );
      return;
    }
    await BtwDialog.show(
      context,
      backend: widget.chatController.backend,
      agentKey: agent.key,
      sessionId: sessionId,
      language: widget.settingsController.language,
    );
  }

  Future<void> _exportMarkdown() async {
    try {
      final ConversationExport export = await widget.chatController
          .exportCurrentSessionMarkdown();
      final List<int> bytes = utf8.encode(export.markdown);
      final DownloadSaveResult saved = await saveDownloadStream(
        fileName: export.fileName,
        total: bytes.length,
        bytes: Stream<List<int>>.value(bytes),
        onProgress: (_, __) {},
      );
      if (!mounted) return;
      final String message = saved.isBrowserDownload
          ? context.l10n.savedToBrowserDownloads
          : context.l10n.savedTo(saved.path ?? export.fileName);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.exportFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool usePermanentSidebar = MediaQuery.sizeOf(context).width >= 900;
    final Widget sidebar = CliAgentsDrawer(
      agentsController: widget.agentsController,
      chatController: widget.chatController,
      machinesController: widget.machinesController,
      settingsController: widget.settingsController,
      closeOnAction: !usePermanentSidebar,
    );
    return Scaffold(
      drawerScrimColor: Colors.black54,
      drawer: usePermanentSidebar
          ? null
          : Drawer(child: SafeArea(child: sidebar)),
      appBar: usePermanentSidebar
          ? null
          : AppBar(
              leading: Builder(
                builder: (BuildContext context) {
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    tooltip: context.l10n.menu,
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  );
                },
              ),
              title: _ChatTitle(
                agentsController: widget.agentsController,
                machinesController: widget.machinesController,
                chatController: widget.chatController,
              ),
              actions: <Widget>[
                _BtwButton(
                  agentsController: widget.agentsController,
                  chatController: widget.chatController,
                  onPressed: _showBtw,
                ),
                _SearchButton(
                  chatController: widget.chatController,
                  onPressed: _showHistorySearch,
                ),
              ],
            ),
      body: SafeArea(
        child: Row(
          children: <Widget>[
            if (usePermanentSidebar)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  border: Border(
                    right: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: SizedBox(width: 320, child: sidebar),
              ),
            Expanded(
              child: Column(
                children: <Widget>[
                  if (usePermanentSidebar)
                    _DesktopChatHeader(
                      agentsController: widget.agentsController,
                      machinesController: widget.machinesController,
                      chatController: widget.chatController,
                      onSearch: _showHistorySearch,
                      onBtw: _showBtw,
                    ),
                  ListenableBuilder(
                    listenable: Listenable.merge(<Listenable>[
                      widget.agentsController,
                      widget.chatController,
                    ]),
                    builder: (BuildContext context, Widget? _) {
                      if (widget.chatController.machine == null) {
                        return const SizedBox.shrink();
                      }
                      final CliAgent agent =
                          widget.agentsController.activeAgent;
                      // Only OAuth agents (claude/codex) prompt to log in.
                      // hermes/opencode manage their key on the host, so they
                      // never show the "not logged in" banner.
                      if (agent.authKind != 'oauth' ||
                          widget.chatController.agentLoggedIn(agent.key) !=
                              false) {
                        return const SizedBox.shrink();
                      }
                      return _NotLoggedInBanner(
                        agentLabel: agent.label,
                        onRecheck: widget.chatController.refreshAuthStatus,
                      );
                    },
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: Listenable.merge(<Listenable>[
                        widget.agentsController,
                        widget.chatController,
                      ]),
                      builder: (BuildContext context, Widget? _) {
                        if (widget.chatController.machine == null) {
                          return _HomeNavigationPage(
                            agentsController: widget.agentsController,
                            chatController: widget.chatController,
                            machinesController: widget.machinesController,
                            settingsController: widget.settingsController,
                          );
                        }
                        final CliAgent agent =
                            widget.agentsController.activeAgent;
                        final List<ChatMessage> messages =
                            widget.chatController.messages;
                        if (widget.chatController.isHistoryLoading &&
                            messages.isEmpty) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (messages.isEmpty) {
                          return _EmptyChatPlaceholder(agentName: agent.label);
                        }
                        // SelectionArea keeps bubble text selectable/copyable
                        // without each bubble building its own overlay-based
                        // SelectableText (see MessageText), which crashed on
                        // conversation teardown.
                        return SelectionArea(
                            child: ListView.builder(
                          controller: _scroll,
                          // Reversed: offset 0 is the bottom, so opening or
                          // switching a conversation lands on the newest message
                          // instantly with no top-to-bottom jump.
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                          itemCount: messages.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ChatMessage message =
                                messages[messages.length - 1 - index];
                            if (widget.chatController.isNoticeMessage(
                              message,
                            )) {
                              return _ChatNotice(text: message.content);
                            }
                            // RepaintBoundary isolates each bubble's painting so
                            // a streaming bubble does not repaint the visible
                            // history every frame.
                            return RepaintBoundary(
                              key: ValueKey<String>(message.id),
                              child: _MessageBubble(
                                message: message,
                                retryable: widget.chatController.isRetryable(
                                  message,
                                ),
                                streaming: widget.chatController.isStreaming(
                                  message,
                                ),
                                awaitingFirstToken: widget.chatController
                                    .isAwaitingFirstToken(message),
                                errorDetail: widget.chatController
                                    .errorDetailFor(message),
                                system: widget.chatController.isSystemMessage(
                                  message,
                                ),
                                cancelled: widget.chatController.isCancelled(
                                  message,
                                ),
                                queued: widget.chatController.isQueued(message),
                                progressLines: widget.chatController
                                    .progressLinesFor(message),
                                onRetry: () =>
                                    widget.chatController.retry(message),
                                onCancelQueued: () =>
                                    widget.chatController.cancelQueued(message),
                                onOptionSelected: (String option) =>
                                    widget.chatController.sendUserText(option),
                              ),
                            );
                          },
                        ),
                        );
                      },
                    ),
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge(<Listenable>[
                      widget.agentsController,
                      widget.chatController,
                    ]),
                    builder: (BuildContext context, Widget? _) {
                      if (widget.chatController.machine == null) {
                        return const SizedBox.shrink();
                      }
                      return _InputBar(
                        controller: _input,
                        backend: widget.chatController.backend,
                        agentKey: widget.agentsController.activeAgent.key,
                        isThinking: widget.chatController.isThinking,
                        isCancelling: widget.chatController.isCancelling,
                        onSend: _send,
                        onCancel: widget.chatController.cancelActiveTurn,
                        onClear: _confirmClearHistory,
                        onCompress: _sendCompact,
                        onExportMarkdown: _exportMarkdown,
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopChatHeader extends StatelessWidget {
  const _DesktopChatHeader({
    required this.agentsController,
    required this.machinesController,
    required this.chatController,
    required this.onSearch,
    required this.onBtw,
  });

  final CliAgentsController agentsController;
  final MachineCredentialsController machinesController;
  final BotChatController chatController;
  final VoidCallback onSearch;
  final VoidCallback onBtw;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: _ChatTitle(
                  agentsController: agentsController,
                  machinesController: machinesController,
                  chatController: chatController,
                ),
              ),
              _BtwButton(
                agentsController: agentsController,
                chatController: chatController,
                onPressed: onBtw,
              ),
              _SearchButton(
                chatController: chatController,
                onPressed: onSearch,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatTitle extends StatelessWidget {
  const _ChatTitle({
    required this.agentsController,
    required this.machinesController,
    required this.chatController,
  });

  final CliAgentsController agentsController;
  final MachineCredentialsController machinesController;
  final BotChatController chatController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        agentsController,
        machinesController,
        chatController,
      ]),
      builder: (BuildContext context, Widget? _) {
        final bool hasChatTarget = chatController.machine != null;
        final MachineCredential? machine = machinesController.activeMachine;
        final AgentSession? session = chatController.activeSession;
        final String subtitle = <String>[
          if (hasChatTarget && machine != null) machine.displayName,
          if (hasChatTarget && session != null) session.name,
        ].join(' - ');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              hasChatTarget
                  ? agentsController.activeAgent.label
                  : context.l10n.home,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  fontSize: 12,
                ),
              ),
          ],
        );
      },
    );
  }
}

// The /btw sidekick entry point, sitting just left of search. It stays enabled
// while the main agent is working — that is exactly when a quick side question
// is useful. Empty conversations surface the normal "needs conversation" hint.
class _BtwButton extends StatelessWidget {
  const _BtwButton({
    required this.agentsController,
    required this.chatController,
    required this.onPressed,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        agentsController,
        chatController,
      ]),
      builder: (BuildContext context, Widget? _) {
        if (chatController.machine == null) {
          return const SizedBox.shrink();
        }
        final String agentKey = agentsController.activeAgent.key;
        const Set<String> btwAgents = <String>{'claude', 'codex'};
        if (!btwAgents.contains(agentKey)) {
          return const SizedBox.shrink();
        }
        return IconButton(
          icon: const SizedBox(
            width: 32,
            child: Text(
              'BTW',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
          tooltip: context.l10n.btwTooltip,
          onPressed: onPressed,
        );
      },
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.chatController, required this.onPressed});

  final BotChatController chatController;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: chatController,
      builder: (BuildContext context, Widget? _) {
        if (chatController.machine == null) {
          return const SizedBox.shrink();
        }
        return IconButton(
          icon: const Icon(Icons.search_rounded),
          tooltip: context.l10n.searchChats,
          onPressed: chatController.isThinking ? null : onPressed,
        );
      },
    );
  }
}

class _NotLoggedInBanner extends StatelessWidget {
  const _NotLoggedInBanner({required this.agentLabel, required this.onRecheck});

  final String agentLabel;
  final Future<void> Function() onRecheck;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.lock_outline_rounded,
              size: 18,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.agentNotLoggedInBanner(agentLabel),
                style: TextStyle(color: colors.onErrorContainer, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () => onRecheck(),
              child: Text(context.l10n.recheck),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChatPlaceholder extends StatelessWidget {
  const _EmptyChatPlaceholder({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        context.l10n.startChat(agentName),
        style: TextStyle(
          color: Theme.of(context).colorScheme.outline,
          fontSize: 14,
        ),
      ),
    );
  }
}

class _HomeNavigationPage extends StatefulWidget {
  const _HomeNavigationPage({
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
    required this.settingsController,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;
  final AppSettingsController settingsController;

  @override
  State<_HomeNavigationPage> createState() => _HomeNavigationPageState();
}

class _HomeNavigationPageState extends State<_HomeNavigationPage> {
  bool _loading = false;
  List<ChatGroup> _swarms = const <ChatGroup>[];
  List<_RecentAgentSession> _agentSessions = const <_RecentAgentSession>[];
  String? _lastMachineId;
  String _lastAgentState = '';

  @override
  void initState() {
    super.initState();
    widget.agentsController.addListener(_onSourceChanged);
    widget.machinesController.addListener(_onSourceChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    widget.agentsController.removeListener(_onSourceChanged);
    widget.machinesController.removeListener(_onSourceChanged);
    super.dispose();
  }

  void _onSourceChanged() {
    final String? machineId = widget.machinesController.activeMachine?.id;
    final String agentState = _agentStateSignature(
      widget.agentsController.agents,
    );
    if (machineId == _lastMachineId && agentState == _lastAgentState) {
      setState(() {});
      return;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final MachineCredential? machine = widget.machinesController.activeMachine;
    final List<CliAgent> agents = widget.agentsController.agents;
    _lastMachineId = machine?.id;
    _lastAgentState = _agentStateSignature(agents);
    if (machine == null) {
      if (!mounted) return;
      setState(() {
        _swarms = const <ChatGroup>[];
        _agentSessions = const <_RecentAgentSession>[];
        _loading = false;
      });
      return;
    }

    setState(() => _loading = true);
    List<ChatGroup> swarms = const <ChatGroup>[];
    try {
      swarms = await widget.chatController.backend.fetchGroups();
    } catch (_) {
      swarms = const <ChatGroup>[];
    }

    final List<_RecentAgentSession> sessions = <_RecentAgentSession>[];
    await Future.wait<void>(
      agents.map((CliAgent agent) async {
        try {
          final AgentSessionList list = await widget.chatController.backend
              .fetchSessions(agent.key);
          for (final AgentSession session in list.sessions) {
            sessions.add(_RecentAgentSession(agent: agent, session: session));
          }
        } catch (_) {
          // A missing CLI or offline backend should not break the home page.
        }
      }),
    );
    sessions.sort(
      (_RecentAgentSession a, _RecentAgentSession b) =>
          b.session.updatedAt.compareTo(a.session.updatedAt),
    );
    if (!mounted) return;
    setState(() {
      _swarms = swarms.take(5).toList(growable: false);
      _agentSessions = sessions.take(6).toList(growable: false);
      _loading = false;
    });
  }

  Future<void> _openSwarm(ChatGroup swarm) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GroupChatScreen(
          agentsController: widget.agentsController,
          settingsController: widget.settingsController,
          initialGroupId: swarm.id,
        ),
      ),
    );
    if (mounted) unawaited(_refresh());
  }

  Future<void> _openAgentSession(_RecentAgentSession entry) async {
    final MachineCredential? machine = widget.machinesController.activeMachine;
    if (!isCliAgentSelectable(entry.agent)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(agentUnavailableMessage(context.l10n, entry.agent)),
        ),
      );
      return;
    }
    if (machine == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.importOrChooseMachine)),
      );
      return;
    }
    if (widget.chatController.isThinking) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.agentBusyRetryLater)));
      return;
    }
    await widget.agentsController.setActive(entry.agent.key);
    await widget.chatController.loadFor(entry.agent, machine);
    await widget.chatController.selectSession(entry.agent, entry.session.id);
  }

  void _openGettingStarted() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const GettingStartedScreen()),
    );
  }

  void _openCredentials() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MachineCredentialsScreen(
          machinesController: widget.machinesController,
          agentsController: widget.agentsController,
          backendClient: widget.chatController.backend,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    final MachineCredential? machine = widget.machinesController.activeMachine;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    strings.home,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    strings.homeSubtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  if (_loading) const SizedBox(height: 12),
                  Text(
                    strings.currentMachine,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (machine == null)
                    _HomeSectionCard(
                      child: ListTile(
                        leading: const Icon(Icons.link_off_rounded),
                        title: Text(strings.notConnected),
                        subtitle: Text(strings.importOrChooseMachine),
                      ),
                    )
                  else
                    ActiveMachineStatusTile(
                      activeMachine: machine,
                      chatController: widget.chatController,
                    ),
                  const SizedBox(height: 12),
                  _HomeSectionCard(
                    child: ListTile(
                      leading: const Icon(Icons.vpn_key_outlined),
                      title: Text(strings.manageCredentials),
                      subtitle: Text(strings.manageCredentialsHomeHint),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openCredentials,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _HomeSectionCard(
                    child: ListTile(
                      leading: const Icon(Icons.school_outlined),
                      title: Text(strings.gettingStarted),
                      subtitle: Text(strings.gettingStartedHomeHint),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openGettingStarted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _HomeSection(
                    title: strings.recentSwarms,
                    emptyText: strings.noRecentSwarms,
                    children: <Widget>[
                      for (final ChatGroup swarm in _swarms)
                        ListTile(
                          leading: const Icon(Icons.groups_outlined),
                          title: Text(
                            swarm.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            swarm.memberLabels.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openSwarm(swarm),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _HomeSection(
                    title: strings.recentAgentSessions,
                    emptyText: strings.noRecentAgentSessions,
                    children: <Widget>[
                      for (final _RecentAgentSession entry in _agentSessions)
                        Builder(
                          builder: (BuildContext context) {
                            final bool usable = isCliAgentSelectable(
                              entry.agent,
                            );
                            final Color? textColor = usable
                                ? null
                                : theme.colorScheme.onSurfaceVariant;
                            return ListTile(
                              leading: Icon(
                                Icons.smart_toy_outlined,
                                color: textColor,
                              ),
                              title: Text(
                                strings.agentSessionLabel(
                                  entry.agent.label,
                                  entry.session.name,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: textColor),
                              ),
                              subtitle: Text(
                                usable
                                    ? formatShortTime(
                                        context,
                                        entry.session.updatedAt
                                            .toIso8601String(),
                                      )
                                    : agentUnavailableMessage(
                                        strings,
                                        entry.agent,
                                      ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  AgentStatusLights(
                                    agent: entry.agent,
                                    compact: true,
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.chevron_right),
                                ],
                              ),
                              onTap: () => _openAgentSession(entry),
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    strings.chooseConversationTarget,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.emptyText,
    required this.children,
  });

  final String title;
  final String emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        _HomeSectionCard(
          child: children.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    emptyText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Column(
                  children: <Widget>[
                    for (int index = 0; index < children.length; index += 1)
                      Column(
                        children: <Widget>[
                          if (index > 0) const Divider(height: 1),
                          children[index],
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _HomeSectionCard extends StatelessWidget {
  const _HomeSectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: child,
    );
  }
}

String _agentStateSignature(List<CliAgent> agents) {
  return agents
      .map(
        (CliAgent agent) => <Object?>[
          agent.key,
          agent.installed,
          agent.authed,
          agent.usable,
          agent.authKind,
        ].join(':'),
      )
      .join('|');
}

class _RecentAgentSession {
  const _RecentAgentSession({required this.agent, required this.session});

  final CliAgent agent;
  final AgentSession session;
}

class _HistorySearchDialog extends StatefulWidget {
  const _HistorySearchDialog({required this.chatController});

  final BotChatController chatController;

  @override
  State<_HistorySearchDialog> createState() => _HistorySearchDialogState();
}

class _HistorySearchDialogState extends State<_HistorySearchDialog> {
  final TextEditingController _query = TextEditingController();
  Future<List<ChatHistorySearchResult>>? _future;
  bool _currentAgentOnly = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final String query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _future = widget.chatController.searchHistory(
        query,
        currentAgentOnly: _currentAgentOnly,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.searchChats),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _query,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: context.l10n.searchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _currentAgentOnly,
                title: Text(context.l10n.currentAgentOnly),
                onChanged: (bool value) {
                  setState(() {
                    _currentAgentOnly = value;
                  });
                  if (_future != null) _search();
                },
              ),
              SizedBox(
                height: 320,
                child: _HistorySearchResults(
                  future: _future,
                  onSelected: (ChatHistorySearchResult result) =>
                      Navigator.of(context).pop(result),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _search, child: Text(context.l10n.searchChats)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }
}

class _HistorySearchResults extends StatelessWidget {
  const _HistorySearchResults({required this.future, required this.onSelected});

  final Future<List<ChatHistorySearchResult>>? future;
  final ValueChanged<ChatHistorySearchResult> onSelected;

  @override
  Widget build(BuildContext context) {
    if (future == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<ChatHistorySearchResult>>(
      future: future,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<ChatHistorySearchResult>> snapshot,
          ) {
            final ColorScheme colors = Theme.of(context).colorScheme;
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text(
                context.l10n.searchFailed(snapshot.error!),
                style: TextStyle(color: colors.error),
              );
            }
            final List<ChatHistorySearchResult> results =
                snapshot.data ?? const <ChatHistorySearchResult>[];
            if (results.isEmpty) {
              return Align(
                alignment: Alignment.topLeft,
                child: Text(
                  context.l10n.noSearchResults,
                  style: TextStyle(color: colors.outline),
                ),
              );
            }
            return ListView.separated(
              shrinkWrap: true,
              itemCount: results.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final ChatHistorySearchResult result = results[index];
                final CliAgent agent = cliAgentByKey(result.agentKey);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${agent.label} - ${result.sessionName}'),
                  subtitle: Text(
                    result.snippet,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => onSelected(result),
                );
              },
            );
          },
    );
  }
}

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.controller,
    required this.backend,
    required this.agentKey,
    required this.isThinking,
    required this.isCancelling,
    required this.onSend,
    required this.onCancel,
    required this.onClear,
    required this.onCompress,
    required this.onExportMarkdown,
  });

  final TextEditingController controller;
  final BackendClient backend;
  final String agentKey;
  final bool isThinking;
  final bool isCancelling;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final VoidCallback onClear;
  final VoidCallback onCompress;
  final VoidCallback onExportMarkdown;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final FocusNode _inputFocus = FocusNode();
  bool _actionsOpen = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    _inputFocus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      _hasText = widget.controller.text.trim().isNotEmpty;
      widget.controller.addListener(_onTextChanged);
    }
    if (widget.isThinking && _actionsOpen) {
      _actionsOpen = false;
    }
    // Hardware-keyboard targets should stay ready for the next prompt after a
    // turn finishes. On mobile we leave focus alone so the soft keyboard does
    // not reopen after every reply.
    if (usesHardwareKeyboard && oldWidget.isThinking && !widget.isThinking) {
      _inputFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _inputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final bool nextHasText = widget.controller.text.trim().isNotEmpty;
    if (nextHasText == _hasText && !(nextHasText && _actionsOpen)) return;
    setState(() {
      _hasText = nextHasText;
      if (nextHasText) _actionsOpen = false;
    });
  }

  void _onFocusChanged() {
    if (!_inputFocus.hasFocus || !_actionsOpen) return;
    setState(() => _actionsOpen = false);
  }

  void _toggleActions() {
    if (widget.isThinking || _hasText) return;
    _inputFocus.unfocus();
    setState(() => _actionsOpen = !_actionsOpen);
  }

  void _closeActions() {
    if (!_actionsOpen) return;
    setState(() => _actionsOpen = false);
  }

  void _sendText() {
    // Sending is allowed even while a turn runs: the controller queues the text
    // as a follow-up and auto-sends it when the conversation frees up.
    if (!_hasText) return;
    _closeActions();
    widget.onSend();
  }

  void _runAction(VoidCallback action) {
    _closeActions();
    action();
  }

  void _submitFromKeyboard() {
    if (!usesHardwareKeyboard) return;
    _sendText();
  }

  @override
  Widget build(BuildContext context) {
    final bool canCancel = widget.isThinking && !widget.isCancelling;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget input = _MessageTextField(
      focusNode: _inputFocus,
      controller: widget.controller,
      enabled: true,
      hintText: widget.isThinking
          ? context.l10n.inputHintFollowUp
          : context.l10n.inputHint,
      onTap: _closeActions,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1024),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: usesHardwareKeyboard
                          ? CallbackShortcuts(
                              bindings: <ShortcutActivator, VoidCallback>{
                                const SingleActivator(LogicalKeyboardKey.enter):
                                    _submitFromKeyboard,
                              },
                              child: input,
                            )
                          : input,
                    ),
                    const SizedBox(width: 8),
                    SizedBox.square(
                      dimension: 44,
                      child: IconButton.filledTonal(
                        // With text present, the button always sends (queuing a
                        // follow-up while a turn runs). With no text mid-turn it
                        // stops the turn; otherwise it opens the actions panel.
                        onPressed: _hasText
                            ? _sendText
                            : widget.isThinking
                            ? canCancel
                                  ? widget.onCancel
                                  : null
                            : _toggleActions,
                        icon: Icon(
                          _hasText
                              ? Icons.arrow_upward_rounded
                              : widget.isThinking
                              ? Icons.stop_rounded
                              : Icons.add_rounded,
                        ),
                        tooltip: _hasText
                            ? context.l10n.send
                            : widget.isThinking
                            ? context.l10n.stop
                            : context.l10n.moreChatActions,
                      ),
                    ),
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: _actionsOpen
                      ? _ComposerActionPanel(
                          backend: widget.backend,
                          agentKey: widget.agentKey,
                          onOpenSettingsPage: _closeActions,
                          onClear: () => _runAction(widget.onClear),
                          onCompress: () => _runAction(widget.onCompress),
                          onExportMarkdown: () =>
                              _runAction(widget.onExportMarkdown),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageTextField extends StatelessWidget {
  const _MessageTextField({
    required this.focusNode,
    required this.controller,
    required this.enabled,
    required this.hintText,
    required this.onTap,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final bool enabled;
  final String hintText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return TextField(
      focusNode: focusNode,
      controller: controller,
      enabled: enabled,
      onTap: onTap,
      minLines: 1,
      maxLines: 6,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: hintText,
        filled: true,
        fillColor: colors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}

class _ComposerActionPanel extends StatelessWidget {
  const _ComposerActionPanel({
    required this.backend,
    required this.agentKey,
    required this.onOpenSettingsPage,
    required this.onClear,
    required this.onCompress,
    required this.onExportMarkdown,
  });

  final BackendClient backend;
  final String agentKey;
  final VoidCallback onOpenSettingsPage;
  final VoidCallback onClear;
  final VoidCallback onCompress;
  final VoidCallback onExportMarkdown;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AgentControlsButtons(
            backend: backend,
            agentKey: agentKey,
            onOpenPage: onOpenSettingsPage,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: <Widget>[
              ComposerActionButton(
                icon: Icons.refresh_rounded,
                label: context.l10n.clearChat,
                onPressed: onClear,
              ),
              ComposerActionButton(
                icon: Icons.compress,
                label: context.l10n.compress,
                onPressed: onCompress,
              ),
              ComposerActionButton(
                icon: Icons.download_outlined,
                label: context.l10n.exportMarkdown,
                onPressed: onExportMarkdown,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// A centered, muted one-line status note (e.g. "Conversation compacted")
// rendered inline in the message list instead of as a chat bubble.
class _ChatNotice extends StatelessWidget {
  const _ChatNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ),
    );
  }
}

// The turn's persisted execution steps.
List<String> _persistedSteps(ChatMessage message) {
  final Object? raw = message.metadata['progressLines'];
  if (raw is! List) return const <String>[];
  return raw
      .whereType<String>()
      .where((String line) => line.trim().isNotEmpty)
      .toList(growable: false);
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.retryable,
    required this.streaming,
    required this.awaitingFirstToken,
    required this.errorDetail,
    required this.system,
    required this.cancelled,
    required this.queued,
    required this.progressLines,
    required this.onRetry,
    required this.onCancelQueued,
    required this.onOptionSelected,
  });

  final ChatMessage message;
  final bool retryable;
  final bool streaming;
  final bool awaitingFirstToken;
  final String? errorDetail;
  final bool system;
  final bool cancelled;
  final bool queued;
  final List<String> progressLines;
  final VoidCallback onRetry;
  final VoidCallback onCancelQueued;
  final void Function(String option) onOptionSelected;

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.isUser;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double maxBubbleWidth = isDesktopTarget
        ? 760
        : MediaQuery.sizeOf(context).width * 0.80;
    final Color bubbleColor = system
        ? colors.tertiaryContainer
        : isUser
        ? colors.primary
        : colors.surfaceContainerHighest;
    final Color textColor = isUser && !system
        ? colors.onPrimary
        : colors.onSurface;
    final Border? border = isUser && !system
        ? null
        : Border.all(color: colors.outlineVariant);

    // A turn can leave several assistant messages (mid-task follow-ups + a final
    // answer); render them as separate, individually timestamped blocks. A single
    // message keeps the simpler one-block layout with a single timestamp below.
    final List<MessageSegment> segments = message.segments;
    final bool segmented = !isUser && !system && segments.length > 1;
    // Claude sometimes ends a finished answer with a "pick one" question + list;
    // surface those choices as buttons that send the pick back as a new message.
    final List<String>? optionPrompt = (!isUser && !system && !streaming)
        ? parseOptionPrompt(
            segments.isNotEmpty ? segments.last.text : message.content,
          )
        : null;
    // Claude and Codex often open with an "I will …" plan; fold it away on the
    // finished bubble.
    final ({String plan, String body})? planSplit = (!isUser &&
            !system &&
            !streaming &&
            !segmented &&
            message.content.isNotEmpty)
        ? splitLeadingPlan(message.content)
        : null;
    // Execution steps captured during the turn, surfaced collapsed once it ends
    // (live progress still streams via `progressLines` below while running).
    final List<String> finishedSteps = (!isUser && !system && !streaming)
        ? _persistedSteps(message)
        : const <String>[];
    final DateTime stampTime =
        (!isUser && segments.isNotEmpty && segments.first.createdAt != null)
        ? segments.first.createdAt!
        : message.createdAt;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              // A queued follow-up is dimmed until it is actually sent.
              color: queued ? bubbleColor.withValues(alpha: 0.55) : bubbleColor,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (awaitingFirstToken && message.content.isEmpty)
                  TypingDots(color: textColor)
                else if (segmented)
                  SegmentedContent(
                    segments: segments,
                    color: textColor,
                    formatInlineEmphasis: !streaming,
                  )
                else if (message.content.isNotEmpty)
                  if (planSplit != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        CollapsibleNote(
                          title: context.l10n.agentThinking,
                          color: textColor,
                          child: MessageText(
                            text: planSplit.plan,
                            color: textColor,
                            formatInlineEmphasis: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        MessageText(
                          text: planSplit.body,
                          color: textColor,
                          formatInlineEmphasis: true,
                        ),
                      ],
                    )
                  else
                    MessageText(
                      text: message.content,
                      color: textColor,
                      formatInlineEmphasis: !isUser && !streaming,
                    ),
                if (optionPrompt != null)
                  OptionButtons(
                    options: optionPrompt,
                    color: textColor,
                    onSelected: onOptionSelected,
                  ),
                if (progressLines.isNotEmpty) ...<Widget>[
                  if (message.content.isNotEmpty) const SizedBox(height: 8),
                  ProgressLines(
                    lines: progressLines,
                    color: textColor,
                  ),
                ] else if (finishedSteps.isNotEmpty) ...<Widget>[
                  if (message.content.isNotEmpty) const SizedBox(height: 6),
                  CollapsibleNote(
                    title: context.l10n.agentSteps(finishedSteps.length),
                    color: textColor,
                    child: ProgressLines(
                      lines: finishedSteps,
                      color: textColor,
                    ),
                  ),
                ],
                if (cancelled) ...<Widget>[
                  if (message.content.isNotEmpty || progressLines.isNotEmpty)
                    const SizedBox(height: 8),
                  MessageStatus(
                    icon: Icons.stop_circle_outlined,
                    text: context.l10n.cancelled,
                    color: textColor,
                  ),
                ],
              ],
            ),
          ),
          // A pending follow-up shows a "queued" affordance instead of a time:
          // it has not been sent yet and can still be cancelled.
          if (queued)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.schedule_rounded, size: 13, color: colors.outline),
                  const SizedBox(width: 4),
                  Text(
                    context.l10n.queuedFollowUp,
                    style: TextStyle(fontSize: 11, color: colors.outline),
                  ),
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: onCancelQueued,
                    child: Text(
                      context.l10n.cancel,
                      style: TextStyle(fontSize: 11, color: colors.primary),
                    ),
                  ),
                ],
              ),
            )
          // Every message shows when it was sent/received. Segmented bubbles also
          // carry an inline time per follow-up, so the trailing stamp is hidden
          // for them to avoid duplicating the last segment's time.
          else if (!segmented &&
              !(awaitingFirstToken && message.content.isEmpty))
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              child: Text(
                formatShortTime(context, stampTime.toIso8601String()),
                style: TextStyle(fontSize: 11, color: colors.outline),
              ),
            ),
          if (retryable) ...<Widget>[
            if (errorDetail != null && errorDetail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  errorDetail!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 1, bottom: 4),
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(context.l10n.retry),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
