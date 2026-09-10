import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_session.dart';
import '../../core/models/group.dart';
import '../../core/models/machine_credential.dart';
import '../../core/models/cli_agent.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/widgets/agent_icon.dart';
import '../chat/bot_chat_controller.dart';
import '../chat/group_chat_screen.dart';
import '../machines/machine_credentials_controller.dart';
import '../machines/machine_credentials_screen.dart';
import '../machines/machine_details_screen.dart';
import '../settings/app_settings_screen.dart';
import '../filesystem/file_system_screen.dart';
import '../quota/quota_scheduler_screen.dart';
import '../quota/quota_usage_screen.dart';
import 'agent_status_lights.dart';
import 'cli_agents_controller.dart';

class CliAgentsDrawer extends StatelessWidget {
  const CliAgentsDrawer({
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
    required this.settingsController,
    this.closeOnAction = true,
    super.key,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;
  final AppSettingsController settingsController;
  final bool closeOnAction;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        agentsController,
        machinesController,
        chatController,
      ]),
      builder: (BuildContext context, Widget? _) {
        final String activeKey = agentsController.activeAgentKey;
        final MachineCredential? activeMachine =
            machinesController.activeMachine;
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.l10n.appName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ActiveMachineStatusTile(
              activeMachine: activeMachine,
              chatController: chatController,
              agentsController: agentsController,
            ),
            Expanded(
              child: ListView(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: Text(context.l10n.manageCredentials),
                    onTap: () {
                      if (closeOnAction) Navigator.of(context).pop();
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => MachineCredentialsScreen(
                            machinesController: machinesController,
                          ),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.query_stats_outlined),
                    title: Text(context.l10n.usageQuery),
                    onTap: () {
                      if (closeOnAction) Navigator.of(context).pop();
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              QuotaUsageScreen(chatController: chatController),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.schedule_send_outlined),
                    title: Text(context.l10n.quotaScheduler),
                    onTap: () {
                      if (closeOnAction) Navigator.of(context).pop();
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => QuotaSchedulerScreen(
                            chatController: chatController,
                          ),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      context.l10n.cliAgents,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final CliAgent agent in agentsController.agents)
                    ..._agentTiles(context, agent, activeKey, activeMachine),
                  const Divider(height: 16),
                  SwarmDrawerSection(
                    agentsController: agentsController,
                    settingsController: settingsController,
                    chatController: chatController,
                    closeOnAction: closeOnAction,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.home_rounded),
              title: Text(context.l10n.backHome),
              selected: chatController.machine == null,
              onTap: () {
                if (chatController.isThinking) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.agentBusyRetryLater)),
                  );
                  return;
                }
                chatController.goHome();
                if (closeOnAction) Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(context.l10n.fileSystem),
              onTap: () {
                if (closeOnAction) Navigator.of(context).pop();
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        FileSystemScreen(chatController: chatController),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(context.l10n.settings),
              onTap: () {
                if (closeOnAction) Navigator.of(context).pop();
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => AppSettingsScreen(
                      settingsController: settingsController,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  List<Widget> _agentTiles(
    BuildContext context,
    CliAgent agent,
    String activeKey,
    MachineCredential? activeMachine,
  ) {
    final bool selectedAgent =
        chatController.machine != null && agent.key == activeKey;
    final List<AgentSession> sessions = chatController.sessionsFor(agent.key);
    final String? activeSessionId = selectedAgent
        ? chatController.activeSessionId
        : sessions.isNotEmpty
        ? sessions.first.id
        : null;
    final bool usable = isCliAgentSelectable(agent);
    final Color disabledColor = Theme.of(context).colorScheme.outline;
    void showUnavailable() => showAgentUnavailableSnack(context, agent);
    return <Widget>[
      ListTile(
        leading: Opacity(
          opacity: usable ? 1 : 0.45,
          child: AgentIcon(agentKey: agent.key),
        ),
        title: Text(agent.label),
        textColor: usable ? null : disabledColor,
        iconColor: usable ? null : disabledColor,
        selected: selectedAgent,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AgentStatusLights(agent: agent),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: usable
                  ? context.l10n.newSession
                  : agentUnavailableMessage(context.l10n, agent),
              onPressed: usable && sessions.length < _maxSessionsPerAgent
                  ? () => _createSession(context, agent, activeMachine)
                  : null,
            ),
          ],
        ),
        onTap: () async {
          if (!usable) {
            showUnavailable();
            return;
          }
          await agentsController.setActive(agent.key);
          if (activeMachine != null) {
            await chatController.loadFor(agent, activeMachine);
          }
          if (context.mounted && closeOnAction) {
            Navigator.of(context).pop();
          }
        },
        onLongPress: usable ? null : showUnavailable,
      ),
      if (selectedAgent && chatController.sessionsLoadingFor(agent.key))
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      if (selectedAgent)
        for (final AgentSession session in sessions)
          Builder(
            builder: (BuildContext context) {
              final bool running = chatController.sessionRunning(
                agent.key,
                session.id,
              );
              return Padding(
                padding: const EdgeInsets.only(left: 28),
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    session.id == activeSessionId
                        ? Icons.chat_bubble
                        : Icons.chat_bubble_outline,
                    size: 18,
                  ),
                  title: Text(
                    session.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: session.id == activeSessionId,
                  // The default "Main" session can't be deleted — it holds the
                  // original, pre-multi-session conversation for this path.
                  trailing: running || !session.isDefault
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (running) const _RunningSessionIndicator(),
                            if (running && !session.isDefault)
                              const SizedBox(width: 4),
                            if (!session.isDefault)
                              IconButton(
                                icon:
                                    const Icon(Icons.delete_outline, size: 20),
                                tooltip: context.l10n.deleteSession,
                                onPressed: running
                                    ? null
                                    : () =>
                                        _deleteSession(context, agent, session),
                              ),
                          ],
                        )
                      : null,
                  onTap: () async {
                    await agentsController.setActive(agent.key);
                    await chatController.selectSession(agent, session.id);
                    if (context.mounted && closeOnAction) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              );
            },
          ),
    ];
  }

  Future<void> _createSession(
    BuildContext context,
    CliAgent agent,
    MachineCredential? activeMachine,
  ) async {
    final AppStrings strings = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
    final ScaffoldState? scaffold = Scaffold.maybeOf(context);
    if (activeMachine == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(strings.importOrChooseMachine)),
      );
      return;
    }
    final int next = chatController.sessionsFor(agent.key).length + 1;
    final String defaultName = strings.defaultSessionName(next);
    if (closeOnAction && scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
    }
    String draftName = defaultName;
    final String? name = await showDialog<String>(
      context: navigator.context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(strings.newSession),
          content: TextFormField(
            initialValue: defaultName,
            autofocus: true,
            decoration: InputDecoration(labelText: strings.sessionName),
            textInputAction: TextInputAction.done,
            onChanged: (String value) => draftName = value,
            onFieldSubmitted: (String value) =>
                Navigator.of(dialogContext).pop(value.trim()),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(draftName.trim()),
              child: Text(strings.create),
            ),
          ],
        );
      },
    );
    if (name == null) return;
    try {
      await agentsController.setActive(agent.key);
      if (chatController.machine == null) {
        await chatController.loadFor(agent, activeMachine);
      }
      await chatController.createSessionFor(agent, name: name);
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(strings.sessionActionFailed(err))),
      );
    }
  }

  Future<void> _deleteSession(
    BuildContext context,
    CliAgent agent,
    AgentSession session,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(context.l10n.deleteSessionTitle(session.name)),
          content: Text(context.l10n.deleteSessionBody),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(context.l10n.delete),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await chatController.deleteSession(agent, session.id);
    } catch (err) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sessionActionFailed(err))),
      );
    }
  }
}

class _RunningSessionIndicator extends StatelessWidget {
  const _RunningSessionIndicator();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.l10n.sessionRunning,
      child: SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

// Mirrors the backend cap (server/lib/chat-sessions.js MAX_SESSIONS) so the
// "new session" button disables before the create call would be rejected.
const int _maxSessionsPerAgent = 8;

/// The Swarm drawer entry plus an always-visible list of the workspace's swarms
/// as sub-entries. Tapping the header opens the swarm screen on its most-recent
/// swarm (or the create flow when there are none); tapping a sub-entry opens
/// directly into that swarm. The list reloads whenever the user returns from the
/// swarm screen, so creates/deletes there are reflected here.
class SwarmDrawerSection extends StatefulWidget {
  const SwarmDrawerSection({
    required this.agentsController,
    required this.settingsController,
    required this.chatController,
    required this.closeOnAction,
    super.key,
  });

  final CliAgentsController agentsController;
  final AppSettingsController settingsController;
  final BotChatController chatController;
  final bool closeOnAction;

  @override
  State<SwarmDrawerSection> createState() => _SwarmDrawerSectionState();
}

class _SwarmDrawerSectionState extends State<SwarmDrawerSection> {
  List<ChatGroup> _swarms = const <ChatGroup>[];
  String? _lastWorkdir;

  @override
  void initState() {
    super.initState();
    _lastWorkdir = widget.chatController.activeWorkdir;
    widget.chatController.addListener(_onControllerChanged);
    _load();
  }

  @override
  void dispose() {
    widget.chatController.removeListener(_onControllerChanged);
    super.dispose();
  }

  // The chat controller notifies often (every streaming delta); only reload the
  // swarm list when the work directory actually changed, since swarms are keyed
  // to the workspace.
  void _onControllerChanged() {
    final String? workdir = widget.chatController.activeWorkdir;
    if (workdir != _lastWorkdir) {
      _lastWorkdir = workdir;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final List<ChatGroup> swarms = await widget.chatController.backend
          .fetchGroups();
      if (mounted) setState(() => _swarms = swarms);
    } on BackendException {
      // Best-effort: a failed fetch just leaves the last-known list in place.
    }
  }

  Future<void> _openSwarm(BuildContext context, {String? groupId}) async {
    if (widget.closeOnAction) Navigator.of(context).pop();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GroupChatScreen(
          agentsController: widget.agentsController,
          settingsController: widget.settingsController,
          initialGroupId: groupId,
        ),
      ),
    );
    // The roster may have changed on that screen; refresh the sub-entries.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    return Column(
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.groups_outlined),
          title: Text(strings.groupChat),
          subtitle: Text(
            strings.groupChatSubtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _openSwarm(context),
        ),
        for (final ChatGroup swarm in _swarms)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.forum_outlined, size: 18),
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
              onTap: () => _openSwarm(context, groupId: swarm.id),
            ),
          ),
      ],
    );
  }
}

class ActiveMachineStatusTile extends StatefulWidget {
  const ActiveMachineStatusTile({
    required this.activeMachine,
    required this.chatController,
    required this.agentsController,
    super.key,
  });

  final MachineCredential? activeMachine;
  final BotChatController chatController;
  final CliAgentsController agentsController;

  @override
  State<ActiveMachineStatusTile> createState() =>
      _ActiveMachineStatusTileState();
}

class _ActiveMachineStatusTileState extends State<ActiveMachineStatusTile> {
  bool _isLoading = false;
  bool _isOnline = false;
  int _statusRequestSerial = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkStatus();
    });
  }

  @override
  void didUpdateWidget(ActiveMachineStatusTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeMachine?.id != widget.activeMachine?.id) {
      _checkStatus();
    }
  }

  Future<void> _checkStatus() async {
    final int requestSerial = ++_statusRequestSerial;
    final MachineCredential? machine = widget.activeMachine;
    if (machine == null) {
      if (mounted) {
        setState(() {
          _isOnline = false;
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted) setState(() => _isLoading = true);
    bool online = false;
    try {
      online = await widget.chatController.backend
          .health(timeout: const Duration(seconds: 6))
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Unreachable or rejected: shown as offline.
    }
    if (mounted &&
        requestSerial == _statusRequestSerial &&
        widget.activeMachine?.id == machine.id) {
      setState(() {
        _isOnline = online;
        _isLoading = false;
      });
    }
  }

  void _openDetails() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MachineDetailsScreen(
          machine: widget.activeMachine!,
          chatController: widget.chatController,
          agentsController: widget.agentsController,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MachineCredential? machine = widget.activeMachine;
    if (machine == null) {
      return ListTile(
        leading: const Icon(Icons.lens, color: Colors.grey, size: 14),
        title: Text(context.l10n.notConnected),
        subtitle: Text(context.l10n.importOrChooseMachine),
      );
    }

    // The tile's background must come from a Material, not a plain decoration:
    // ListTile paints its ink splash on the nearest Material ancestor, so a
    // DecoratedBox in between would hide the tap feedback.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: _isLoading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  Icons.lens,
                  color: _isOnline
                      ? const Color(0xFF10B981)
                      : const Color(0xFFEF4444),
                  size: 14,
                ),
          title: Text(
            machine.displayName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            _isLoading
                ? context.l10n.loadingStatus
                : (_isOnline ? context.l10n.online : context.l10n.offline),
            style: TextStyle(
              color: _isLoading
                  ? Theme.of(context).colorScheme.outline
                  : (_isOnline
                        ? const Color(0xFF10B981)
                        : const Color(0xFFEF4444)),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: _openDetails,
        ),
      ),
    );
  }
}
