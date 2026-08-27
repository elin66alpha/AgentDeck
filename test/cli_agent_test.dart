import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/features/cli_agents/agent_status_lights.dart';

void main() {
  test('parses agent status fields from backend payload', () {
    final CliAgent agent = CliAgent.fromJson(<String, Object?>{
      'key': 'hermes',
      'label': 'Hermes',
      'description': 'Hermes CLI',
      'installed': true,
      'authed': false,
      'authKind': 'apiKey',
      'usable': false,
    });

    expect(agent.key, 'hermes');
    expect(agent.installed, true);
    expect(agent.authed, false);
    expect(agent.authKind, 'apiKey');
    expect(agent.usable, false);
  });

  test('old agent payloads remain selectable by default', () {
    final CliAgent agent = CliAgent.fromJson(<String, Object?>{
      'key': 'claude',
      'label': 'Claude Code',
      'description': 'Anthropic Claude Code CLI',
    });

    expect(agent.installed, true);
    expect(agent.authed, true);
    expect(agent.usable, true);
    expect(agent.authKind, 'oauth');
  });

  test(
    'derives opencode usability from install state when usable is omitted',
    () {
      final CliAgent installed = CliAgent.fromJson(<String, Object?>{
        'key': 'opencode',
        'label': 'OpenCode',
        'description': 'OpenCode CLI',
        'installed': true,
        'authed': false,
        'authKind': 'apiKeyOptional',
      });
      final CliAgent missing = CliAgent.fromJson(<String, Object?>{
        'key': 'opencode',
        'label': 'OpenCode',
        'description': 'OpenCode CLI',
        'installed': false,
        'authed': false,
        'authKind': 'apiKeyOptional',
      });

      expect(installed.usable, true);
      expect(missing.usable, false);
    },
  );

  test('selection predicate blocks agents that are not usable', () {
    const CliAgent needsLogin = CliAgent(
      key: 'codex',
      label: 'Codex',
      description: 'OpenAI Codex CLI',
      installed: true,
      authed: false,
      usable: false,
      authKind: 'oauth',
    );
    const CliAgent ready = CliAgent(
      key: 'opencode',
      label: 'OpenCode',
      description: 'OpenCode CLI',
      installed: true,
      authed: true,
      usable: true,
      authKind: 'apiKeyOptional',
    );

    expect(isCliAgentSelectable(needsLogin), false);
    expect(isCliAgentSelectable(ready), true);
  });

  test('reads the credential expiry from the backend payload', () {
    final CliAgent agent = CliAgent.fromJson(<String, Object?>{
      'key': 'claude',
      'label': 'Claude Code',
      'description': 'Anthropic Claude Code CLI',
      'credentialExpiresAt': 1893456000000,
    });
    final CliAgent legacy = CliAgent.fromJson(<String, Object?>{
      'key': 'codex',
      'label': 'Codex',
      'description': 'OpenAI Codex CLI',
      'credentialExpiresAt': 1893456000000,
    });

    expect(
      agent.credentialExpiresAt,
      DateTime.fromMillisecondsSinceEpoch(1893456000000),
    );
    expect(legacy.credentialExpiresAt, isNull);
  });

  test('counts whole days on both sides of the credential expiry', () {
    final DateTime now = DateTime(2026, 8, 16, 12);
    CredentialExpiry expiryAfter(Duration offset) =>
        CredentialExpiry.at(now.add(offset), now: now);

    expect(expiryAfter(const Duration(days: 7)).days, 7);
    expect(expiryAfter(const Duration(days: 7)).expired, false);
    // Truncates, so a day and a half of runway still reads as one full day.
    expect(expiryAfter(const Duration(days: 1, hours: 12)).days, 1);
    expect(expiryAfter(const Duration(hours: 3)).days, 0);
    expect(expiryAfter(const Duration(hours: 3)).expired, false);
    expect(expiryAfter(const Duration(hours: -3)).expired, true);
    expect(expiryAfter(const Duration(hours: -3)).days, 0);
    expect(expiryAfter(const Duration(days: -3, hours: -1)).days, 3);
    expect(expiryAfter(const Duration(days: -3, hours: -1)).expired, true);
  });

  test('describes real expiry fields but never Codex token rotation', () {
    const AppStrings strings = AppStrings(AppLanguage.en);
    final DateTime now = DateTime(2026, 8, 16, 12);
    CliAgent claudeExpiring(Duration offset) => CliAgent(
          key: 'claude',
          label: 'Claude Code',
          description: 'Anthropic Claude Code CLI',
          authKind: 'oauth',
          credentialExpiresAt: now.add(offset),
        );

    expect(
      agentCredentialExpiryMessage(
        strings,
        claudeExpiring(const Duration(days: 12)),
        now: now,
      ),
      'Log in again in 12 days',
    );
    expect(
      agentCredentialExpiryMessage(
        strings,
        claudeExpiring(const Duration(days: -2)),
        now: now,
      ),
      'Expired 2 days ago. Log in again on the backend host.',
    );
    expect(
      agentCredentialExpiryMessage(
        strings,
        const CliAgent(
          key: 'opencode',
          label: 'OpenCode',
          description: 'OpenCode CLI',
          authKind: 'apiKeyOptional',
        ),
        now: now,
      ),
      isNull,
    );
    expect(
      agentCredentialExpiryMessage(
        strings,
        CliAgent(
          key: 'codex',
          label: 'Codex',
          description: 'OpenAI Codex CLI',
          authKind: 'oauth',
          credentialExpiresAt: now.subtract(const Duration(days: 2)),
        ),
        now: now,
      ),
      isNull,
    );
  });
}
