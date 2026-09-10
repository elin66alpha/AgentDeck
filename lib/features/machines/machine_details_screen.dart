import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/util/time_format.dart';
import '../chat/bot_chat_controller.dart';
import '../cli_agents/agent_status_lights.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../ssh/ssh_terminal_controller.dart';
import '../ssh/ssh_terminal_screen.dart';

/// One machine on a single page: the SSH terminal entry, CLI agent status, the
/// device tokens issued by its backend, then the backend's status report.
class MachineDetailsScreen extends StatefulWidget {
  const MachineDetailsScreen({
    required this.machine,
    required this.chatController,
    required this.agentsController,
    super.key,
  });

  final MachineCredential machine;
  final BotChatController chatController;
  final CliAgentsController agentsController;

  @override
  State<MachineDetailsScreen> createState() => _MachineDetailsScreenState();
}

class _MachineDetailsScreenState extends State<MachineDetailsScreen> {
  // Owned by the page, so leaving and re-entering SSH reuses one terminal.
  late final SshTerminalController _sshController = SshTerminalController(
    backend: widget.chatController.backend,
  );
  Future<String>? _status;

  @override
  void dispose() {
    _sshController.dispose();
    super.dispose();
  }

  void _enterSsh() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SshTerminalScreen(
          controller: _sshController,
          machineId: widget.machine.id,
        ),
      ),
    );
  }

  Future<void> _refreshAgents() async {
    try {
      final List<CliAgent> agents = await widget.chatController.backend
          .fetchAgents(verifyCredentials: true);
      if (!mounted) return;
      widget.agentsController.syncAgents(agents);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.agentStatusRefreshFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ColorScheme colors = Theme.of(context).colorScheme;
    _status ??= widget.chatController.statusText(strings);
    return Scaffold(
      appBar: AppBar(title: Text(strings.machineDetails)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _enterSsh,
                        icon: const Icon(Icons.terminal_rounded),
                        label: Text(strings.enterSsh),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _AgentCredentialStatusSection(
                      agentsController: widget.agentsController,
                      onRefresh: _refreshAgents,
                    ),
                    const SizedBox(height: 20),
                    _DeviceTokensPanel(chatController: widget.chatController),
                    const SizedBox(height: 20),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            widget.machine.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded),
                          tooltip: strings.refresh,
                          onPressed: () => setState(() {
                            _status = widget.chatController.statusText(strings);
                          }),
                        ),
                      ],
                    ),
                    FutureBuilder<String>(
                      future: _status,
                      builder: (
                        BuildContext context,
                        AsyncSnapshot<String> snap,
                      ) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        return SelectableText(
                          snap.hasError
                              ? strings.statusLoadFailed(snap.error!)
                              : snap.data ?? strings.noStatus,
                          style: TextStyle(
                            color: snap.hasError ? colors.error : null,
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentCredentialStatusSection extends StatelessWidget {
  const _AgentCredentialStatusSection({
    required this.agentsController,
    required this.onRefresh,
  });

  final CliAgentsController agentsController;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AnimatedBuilder(
      animation: agentsController,
      builder: (BuildContext context, Widget? _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      context.l10n.cliAgents,
                      style: TextStyle(
                        color: theme.colorScheme.outline,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.recheck,
                    onPressed: () => unawaited(onRefresh()),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerLow,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: <Widget>[
                  for (int index = 0;
                      index < agentsController.agents.length;
                      index += 1)
                    _AgentCredentialStatusTile(
                      agent: agentsController.agents[index],
                      showDivider: index > 0,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AgentCredentialStatusTile extends StatelessWidget {
  const _AgentCredentialStatusTile({
    required this.agent,
    required this.showDivider,
  });

  final CliAgent agent;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppStrings strings = context.l10n;
    final bool usable = isCliAgentSelectable(agent);
    final Color? textColor = usable ? null : theme.colorScheme.onSurfaceVariant;
    final CredentialExpiry? expiry = cliAgentCredentialExpiry(agent);
    final String? subtitle = usable
        ? (agentCredentialExpiryMessage(strings, agent) ??
            _readySubtitle(strings, agent))
        : agentUnavailableMessage(strings, agent);
    return Column(
      children: <Widget>[
        if (showDivider) const Divider(height: 1),
        ListTile(
          dense: true,
          title: Text(agent.label, style: TextStyle(color: textColor)),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle,
                  style: TextStyle(
                    color: expiry?.expired == true
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                ),
          trailing: Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              AgentStatusLights(agent: agent),
              _AgentCredentialAction(agent: agent),
            ],
          ),
        ),
      ],
    );
  }

  String? _readySubtitle(AppStrings strings, CliAgent agent) {
    if (agent.key == 'opencode') return strings.optionalApiKey;
    if (agent.authKind == 'apiKey') return strings.agentReady;
    if (agent.authKind == 'oauth') return strings.agentReady;
    return null;
  }
}

class _AgentCredentialAction extends StatelessWidget {
  const _AgentCredentialAction({required this.agent});

  final CliAgent agent;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    if (!agent.installed) {
      return OutlinedButton(
        onPressed: null,
        child: Text(strings.unavailable),
      );
    }
    // Every agent's credential is created on the backend host: claude/codex with
    // their own `login` command, hermes/opencode with a provider key. Relay only
    // reports the state it can read there.
    if (agent.key == 'opencode' || agent.key == 'hermes') {
      return OutlinedButton(
        onPressed: null,
        child: Text(strings.keyManagedOnHost),
      );
    }
    return const SizedBox.shrink();
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
