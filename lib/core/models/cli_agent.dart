class CliAgent {
  const CliAgent({
    required this.key,
    required this.label,
    required this.description,
    this.installed = true,
    this.authed = true,
    bool? usable,
    String? authKind,
    this.credentialExpiresAt,
  })  : usable = usable ??
            (installed && (authed || key == 'opencode' || key == 'hermes')),
        authKind = authKind ?? 'unknown';

  factory CliAgent.fromJson(Map<String, Object?> json) {
    final String key = json['key'] as String? ?? 'claude';
    final bool installed = json['installed'] as bool? ?? true;
    final bool authed = json['authed'] as bool? ?? true;
    final Object? expiresAt = json['credentialExpiresAt'];
    return CliAgent(
      key: key,
      label: json['label'] as String? ?? 'Claude Code',
      description: json['description'] as String? ?? '',
      installed: installed,
      authed: authed,
      usable: json['usable'] as bool? ??
          (installed && (authed || key == 'opencode' || key == 'hermes')),
      authKind: json['authKind'] as String? ?? defaultAuthKindForAgent(key),
      credentialExpiresAt: expiresAt is num
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt())
          : null,
    );
  }

  final String key;
  final String label;
  final String description;
  final bool installed;
  final bool authed;
  final bool usable;
  final String authKind;

  /// When the OAuth credential stored on the backend host runs out, so the app
  /// can say how long is left before logging in there again. Null for agents
  /// whose credential carries no expiry (an older backend, or a host-managed
  /// API key).
  final DateTime? credentialExpiresAt;

  bool get selectable => usable;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'key': key,
      'label': label,
      'description': description,
      'installed': installed,
      'authed': authed,
      'usable': usable,
      'authKind': authKind,
      'credentialExpiresAt': credentialExpiresAt?.millisecondsSinceEpoch,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is CliAgent &&
        other.key == key &&
        other.label == label &&
        other.description == description &&
        other.installed == installed &&
        other.authed == authed &&
        other.usable == usable &&
        other.authKind == authKind &&
        other.credentialExpiresAt == credentialExpiresAt;
  }

  @override
  int get hashCode => Object.hash(
        key,
        label,
        description,
        installed,
        authed,
        usable,
        authKind,
        credentialExpiresAt,
      );
}

/// How the stored credential stands right now: whole days until it expires, or
/// whole days since it did. Both sides truncate, so "1 day left" covers 24-48h
/// of runway and "expired 1 day ago" is at least a full day stale.
class CredentialExpiry {
  const CredentialExpiry({required this.expired, required this.days});

  factory CredentialExpiry.at(DateTime expiresAt, {DateTime? now}) {
    final Duration left = expiresAt.difference(now ?? DateTime.now());
    return CredentialExpiry(
      expired: left.isNegative,
      days: left.inDays.abs(),
    );
  }

  /// True once the expiry timestamp is in the past.
  final bool expired;

  /// Whole days of runway left, or whole days since expiry. Zero means the
  /// change happens (or happened) within a day.
  final int days;
}

/// Expiry state of [agent]'s credential, or null when it has none to report.
/// Only the OAuth agents (Claude Code, Codex) ever do.
CredentialExpiry? cliAgentCredentialExpiry(CliAgent agent, {DateTime? now}) {
  final DateTime? expiresAt = agent.credentialExpiresAt;
  if (expiresAt == null) return null;
  return CredentialExpiry.at(expiresAt, now: now);
}

String defaultAuthKindForAgent(String key) {
  switch (key) {
    case 'claude':
    case 'codex':
      return 'oauth';
    case 'hermes':
      return 'apiKey';
    case 'opencode':
      return 'apiKeyOptional';
    default:
      return 'unknown';
  }
}

bool isCliAgentSelectable(CliAgent agent) => agent.selectable;

/// The agents shown before the backend reports which CLIs are actually
/// installed. The live list comes from `/api/agents` with host status fields.
const List<CliAgent> defaultCliAgents = <CliAgent>[
  CliAgent(
    key: 'claude',
    label: 'Claude Code',
    description: 'Anthropic Claude Code CLI',
    authKind: 'oauth',
  ),
  CliAgent(
    key: 'codex',
    label: 'Codex',
    description: 'OpenAI Codex CLI',
    authKind: 'oauth',
  ),
];

/// Every agent the app knows how to label, including experimental ones that may
/// not be visible yet. Used to resolve a key (from history, swarms, etc.) to a
/// display label regardless of current availability.
const List<CliAgent> knownCliAgents = <CliAgent>[
  ...defaultCliAgents,
  CliAgent(
    key: 'opencode',
    label: 'OpenCode',
    description: 'OpenCode CLI',
    authKind: 'apiKeyOptional',
  ),
  CliAgent(
    key: 'hermes',
    label: 'Hermes',
    description: 'Hermes CLI',
    authKind: 'apiKey',
  ),
];

CliAgent cliAgentByKey(String? key) {
  for (final CliAgent agent in knownCliAgents) {
    if (agent.key == key) return agent;
  }
  return defaultCliAgents.first;
}
