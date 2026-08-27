import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/models/cli_agent.dart';

String agentUnavailableMessage(AppStrings strings, CliAgent agent) {
  if (!agent.installed) return strings.agentCliNotInstalled(agent.label);
  switch (agent.authKind) {
    case 'oauth':
      return strings.agentNeedsLogin(agent.label);
    case 'apiKey':
      return strings.agentNeedsApiKey(agent.label);
    default:
      return strings.agentUnavailable(agent.label);
  }
}

/// How long a credential with a real deadline still has on the backend host.
/// Codex managed auth is intentionally absent because its tokens auto-refresh.
String? agentCredentialExpiryMessage(
  AppStrings strings,
  CliAgent agent, {
  DateTime? now,
}) {
  final CredentialExpiry? expiry = cliAgentCredentialExpiry(agent, now: now);
  if (expiry == null) return null;
  if (expiry.expired) {
    return expiry.days > 0
        ? strings.credentialExpiredDays(expiry.days)
        : strings.credentialExpiredToday;
  }
  return expiry.days > 0
      ? strings.credentialExpiresInDays(expiry.days)
      : strings.credentialExpiresToday;
}

void showAgentUnavailableSnack(BuildContext context, CliAgent agent) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(agentUnavailableMessage(context.l10n, agent))),
  );
}

class AgentStatusLights extends StatelessWidget {
  const AgentStatusLights({
    required this.agent,
    this.compact = false,
    super.key,
  });

  final CliAgent agent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    // Codex can use managed ChatGPT auth or an API key, both of which Relay can
    // detect. Hermes/OpenCode provider keys remain outside this status contract.
    final bool showAuthLight = agent.authKind == 'oauth' ||
        (agent.key == 'codex' && agent.authKind == 'apiKey');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _StatusDot(
          ok: agent.installed,
          tooltip: strings.agentInstalledStatus(agent.installed),
        ),
        if (showAuthLight) ...<Widget>[
          SizedBox(width: compact ? 5 : 7),
          _StatusDot(
            ok: agent.authed,
            tooltip: strings.agentAuthStatus(agent.authed, agent.authKind),
          ),
        ],
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.ok, required this.tooltip});

  final bool ok;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: ok ? Colors.green.shade600 : colors.error,
          border: Border.all(
            color: ok ? Colors.green.shade800 : colors.error,
            width: 0.5,
          ),
        ),
      ),
    );
  }
}
