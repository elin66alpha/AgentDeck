class CliAgent {
  const CliAgent({
    required this.key,
    required this.label,
    required this.description,
    this.installed = true,
    this.authed = true,
    bool? usable,
    String? authKind,
  })  : usable = usable ??
            (installed && (authed || key == 'opencode' || key == 'hermes')),
        authKind = authKind ?? 'unknown';

  factory CliAgent.fromJson(Map<String, Object?> json) {
    final String key = json['key'] as String? ?? 'claude';
    final bool installed = json['installed'] as bool? ?? true;
    final bool authed = json['authed'] as bool? ?? true;
    return CliAgent(
      key: key,
      label: json['label'] as String? ?? 'Claude Code',
      description: json['description'] as String? ?? '',
      installed: installed,
      authed: authed,
      usable: json['usable'] as bool? ??
          (installed && (authed || key == 'opencode' || key == 'hermes')),
      authKind: json['authKind'] as String? ?? defaultAuthKindForAgent(key),
    );
  }

  final String key;
  final String label;
  final String description;
  final bool installed;
  final bool authed;
  final bool usable;
  final String authKind;

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
        other.authKind == authKind;
  }

  @override
  int get hashCode =>
      Object.hash(key, label, description, installed, authed, usable, authKind);
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
