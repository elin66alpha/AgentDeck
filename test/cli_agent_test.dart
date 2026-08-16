import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/features/machines/agent_login_flow_controller.dart';

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

  test('agent login flow tracks URL, submitted code, and completion', () async {
    final StreamController<BackendEvent> events =
        StreamController<BackendEvent>();
    String? submittedSessionId;
    String? submittedCode;
    final AgentLoginFlowController controller = AgentLoginFlowController(
      startLogin: (_) => events.stream,
      submitCode: (String sessionId, String code) async {
        submittedSessionId = sessionId;
        submittedCode = code;
      },
    );
    addTearDown(() async {
      controller.dispose();
      await events.close();
    });

    await controller.start('codex');
    events.add(
      const BackendEvent(
        type: 'login_started',
        data: <String, Object?>{'sessionId': 's1', 'agent': 'codex'},
      ),
    );
    await pumpEventQueue();

    expect(controller.phase, AgentLoginPhase.waitingForUrl);
    expect(controller.sessionId, 's1');

    events.add(
      const BackendEvent(
        type: 'login_url',
        data: <String, Object?>{
          'sessionId': 's1',
          'agent': 'codex',
          'url': 'https://example.test/login',
        },
      ),
    );
    await pumpEventQueue();

    expect(controller.phase, AgentLoginPhase.readyForCode);
    expect(controller.url, 'https://example.test/login');

    await controller.submitCode('  abc123  ');

    expect(controller.phase, AgentLoginPhase.submitting);
    expect(submittedSessionId, 's1');
    expect(submittedCode, 'abc123');

    events.add(
      const BackendEvent(
        type: 'login_done',
        data: <String, Object?>{'sessionId': 's1', 'agent': 'codex'},
      ),
    );
    await pumpEventQueue();

    expect(controller.phase, AgentLoginPhase.done);
  });

  test('agent login flow surfaces stream errors', () async {
    final AgentLoginFlowController controller = AgentLoginFlowController(
      startLogin: (_) => Stream<BackendEvent>.error(
        BackendException('could not start'),
      ),
      submitCode: (_, __) async {},
    );
    addTearDown(controller.dispose);

    await controller.start('claude');
    await pumpEventQueue();

    expect(controller.phase, AgentLoginPhase.error);
    expect(controller.error, 'could not start');
  });
}
