import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_session.dart';
import '../../core/models/group.dart';
import '../../core/models/machine_credential.dart';
import '../../core/models/cli_agent.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/agent_icon.dart';
import '../chat/bot_chat_controller.dart';
import '../chat/group_chat_screen.dart';
import '../machines/machine_credentials_controller.dart';
import '../machines/machine_credentials_screen.dart';
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
                            agentsController: agentsController,
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
                  SwarmDrawerSection(
                    agentsController: agentsController,
                    settingsController: settingsController,
                    chatController: chatController,
                    closeOnAction: closeOnAction,
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
    super.key,
  });

  final MachineCredential? activeMachine;
  final BotChatController chatController;

  @override
  State<ActiveMachineStatusTile> createState() =>
      _ActiveMachineStatusTileState();
}

class _ActiveMachineStatusTileState extends State<ActiveMachineStatusTile> {
  bool _isLoading = false;
  bool _isOnline = false;
  String? _statusText;
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
    final AppStrings strings = context.l10n;
    if (machine == null) {
      if (mounted) {
        setState(() {
          _statusText = null;
          _isOnline = false;
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _statusText = null;
      });
    }

    try {
      final String text = await widget.chatController
          .statusText(strings, timeout: const Duration(seconds: 6))
          .timeout(const Duration(seconds: 8));
      if (mounted &&
          requestSerial == _statusRequestSerial &&
          widget.activeMachine?.id == machine.id) {
        setState(() {
          _statusText = text;
          _isOnline = true;
          _isLoading = false;
        });
      }
    } catch (err) {
      if (mounted &&
          requestSerial == _statusRequestSerial &&
          widget.activeMachine?.id == machine.id) {
        setState(() {
          _statusText = strings.statusLoadFailed(err);
          _isOnline = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _showStatusDialog() async {
    if (widget.activeMachine == null) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: <Widget>[
                  Icon(
                    Icons.lens,
                    color: _isLoading
                        ? Colors.grey
                        : (_isOnline
                              ? const Color(0xFF10B981)
                              : const Color(0xFFEF4444)),
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.activeMachine!.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              content: Container(
                constraints: const BoxConstraints(maxHeight: 520),
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (_isLoading)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24.0),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      else
                        SelectableText(
                          _statusText ?? context.l10n.noStatus,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      _DeviceTokensPanel(chatController: widget.chatController),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: _isLoading
                      ? null
                      : () async {
                          setStateDialog(() {
                            _isLoading = true;
                          });
                          await _checkStatus();
                          if (dialogContext.mounted) {
                            setStateDialog(() {});
                          }
                        },
                  child: Text(context.l10n.refresh),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(context.l10n.close),
                ),
              ],
            );
          },
        );
      },
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
          onTap: _showStatusDialog,
        ),
      ),
    );
  }
}

class _DeviceTokensPanel extends StatefulWidget {
  const _DeviceTokensPanel({required this.chatController});

  final BotChatController chatController;

  @override
  State<_DeviceTokensPanel> createState() => _DeviceTokensPanelState();
}

class _DeviceTokensPanelState extends State<_DeviceTokensPanel> {
  late Future<List<DeviceToken>> _tokensFuture;
  List<DeviceToken> _tokens = const <DeviceToken>[];
  final Set<String> _revoking = <String>{};
  final Set<String> _deleting = <String>{};

  @override
  void initState() {
    super.initState();
    _tokensFuture = _loadTokens();
  }

  Future<List<DeviceToken>> _loadTokens() async {
    final List<DeviceToken> tokens = await widget.chatController.deviceTokens();
    _tokens = tokens;
    return tokens;
  }

  void _refresh() {
    setState(() {
      _tokensFuture = _loadTokens();
    });
  }

  Future<bool> _confirmCurrentRevoke(DeviceToken token) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.revokeCurrentTokenTitle),
        content: Text(context.l10n.revokeCurrentTokenBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.revokeToken),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _revoke(DeviceToken token) async {
    if (token.current && !await _confirmCurrentRevoke(token)) return;
    if (!mounted) return;
    setState(() {
      _revoking.add(token.id);
    });
    try {
      await widget.chatController.revokeDeviceToken(token.id);
      if (!mounted) return;
      final String now = DateTime.now().toUtc().toIso8601String();
      final List<DeviceToken> next = _tokens
          .map(
            (DeviceToken item) => item.id == token.id
                ? item.copyWith(revoked: true, revokedAt: now)
                : item,
          )
          .toList(growable: false);
      setState(() {
        _tokens = next;
        _tokensFuture = Future<List<DeviceToken>>.value(next);
      });
      final String label = token.label.isEmpty ? token.id : token.label;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.tokenRevoked(label))));
      if (!token.current) _refresh();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.tokenRevokeFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _revoking.remove(token.id);
        });
      }
    }
  }

  Future<void> _delete(DeviceToken token) async {
    if (!token.revoked || _deleting.contains(token.id)) return;
    setState(() {
      _deleting.add(token.id);
    });
    try {
      await widget.chatController.deleteDeviceToken(token.id);
      if (!mounted) return;
      final List<DeviceToken> next = _tokens
          .where((DeviceToken item) => item.id != token.id)
          .toList(growable: false);
      setState(() {
        _tokens = next;
        _tokensFuture = Future<List<DeviceToken>>.value(next);
      });
      final String label = token.label.isEmpty ? token.id : token.label;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.tokenDeleted(label))));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.tokenDeleteFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deleting.remove(token.id);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DeviceToken>>(
      future: _tokensFuture,
      builder: (BuildContext context, AsyncSnapshot<List<DeviceToken>> snap) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        final List<DeviceToken> tokens = snap.data ?? _tokens;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    context.l10n.deviceTokens,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: context.l10n.refresh,
                  onPressed: snap.connectionState == ConnectionState.waiting
                      ? null
                      : _refresh,
                ),
              ],
            ),
            if (snap.connectionState == ConnectionState.waiting &&
                tokens.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (snap.hasError && tokens.isEmpty)
              Text(snap.error.toString(), style: TextStyle(color: colors.error))
            else if (tokens.isEmpty)
              Text(
                context.l10n.noDeviceTokens,
                style: TextStyle(color: colors.outline),
              )
            else
              for (final DeviceToken token in tokens)
                _DeviceTokenRow(
                  token: token,
                  busy:
                      _revoking.contains(token.id) ||
                      _deleting.contains(token.id),
                  onRevoke: () => _revoke(token),
                  onDelete: () => _delete(token),
                ),
          ],
        );
      },
    );
  }
}

class _DeviceTokenRow extends StatelessWidget {
  const _DeviceTokenRow({
    required this.token,
    required this.busy,
    required this.onRevoke,
    required this.onDelete,
  });

  final DeviceToken token;
  final bool busy;
  final VoidCallback onRevoke;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String deviceInfo = _tokenDeviceInfo(token);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                token.current
                    ? Icons.phone_android_rounded
                    : Icons.devices_other_rounded,
                color: token.revoked ? colors.outline : colors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          token.label.isEmpty ? token.id : token.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (token.current)
                          _TokenBadge(
                            label: context.l10n.currentDeviceToken,
                            color: colors.primaryContainer,
                            textColor: colors.onPrimaryContainer,
                          ),
                        if (token.revoked)
                          _TokenBadge(
                            label: context.l10n.revokedDeviceToken,
                            color: colors.errorContainer,
                            textColor: colors.onErrorContainer,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.tokenCreatedAt(
                        formatShortTime(context, token.createdAt),
                      ),
                      style: TextStyle(color: colors.outline, fontSize: 12),
                    ),
                    if (token.revokedAt != null)
                      Text(
                        context.l10n.tokenRevokedAt(
                          formatShortTime(context, token.revokedAt),
                        ),
                        style: TextStyle(color: colors.outline, fontSize: 12),
                      ),
                    if (!token.revoked && deviceInfo.isNotEmpty)
                      Text(
                        context.l10n.tokenUsedBy(deviceInfo),
                        style: TextStyle(color: colors.outline, fontSize: 12),
                      ),
                    if (!token.revoked && token.lastUsedAt != null)
                      Text(
                        context.l10n.tokenLastUsedAt(
                          formatShortTime(context, token.lastUsedAt),
                        ),
                        style: TextStyle(color: colors.outline, fontSize: 12),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: token.revoked ? onDelete : onRevoke,
                  child: Text(
                    token.revoked
                        ? context.l10n.deleteToken
                        : context.l10n.revokeToken,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _tokenDeviceInfo(DeviceToken token) {
  final String deviceId = token.lastDeviceId;
  final String shortId = deviceId.length <= 8
      ? deviceId
      : '${deviceId.substring(0, 8)}...';
  if (token.lastDeviceName.isNotEmpty && shortId.isNotEmpty) {
    return '${token.lastDeviceName} ($shortId)';
  }
  return token.lastDeviceName.isNotEmpty ? token.lastDeviceName : shortId;
}

class _TokenBadge extends StatelessWidget {
  const _TokenBadge({
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
