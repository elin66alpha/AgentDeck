import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/agent_session.dart';
import 'package:relay/core/models/chat_message.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/storage/machine_credentials_store.dart';
import 'package:relay/features/chat/bot_chat_controller.dart';
import 'package:relay/features/cli_agents/cli_agents_controller.dart';
import 'package:relay/features/cli_agents/cli_agents_drawer.dart';
import 'package:relay/features/machines/machine_credentials_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('mobile drawer can create a session without framework errors', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();

    final MachineCredential machine = MachineCredential(
      id: 'machine-1',
      name: 'Local test',
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
    final CliAgentsController agentsController = CliAgentsController();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(
      store: _MemoryMachineCredentialsStore(machine),
    );
    final AppSettingsController settingsController = AppSettingsController();
    final _SessionBackendClient backendClient = _SessionBackendClient();
    final BotChatController chatController = BotChatController(
      backendClient: backendClient,
    );
    addTearDown(chatController.disposeController);

    await agentsController.load();
    await machinesController.load();
    await chatController.loadFor(defaultCliAgents.first, machine);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              leading: Builder(
                builder: (BuildContext context) {
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  );
                },
              ),
            ),
            drawer: Drawer(
              child: SafeArea(
                child: CliAgentsDrawer(
                  agentsController: agentsController,
                  chatController: chatController,
                  machinesController: machinesController,
                  settingsController: settingsController,
                ),
              ),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('CLI agents'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('New session'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(backendClient.createdSessions, 1);
    expect(chatController.sessionsFor('claude'), hasLength(2));
    expect(chatController.activeSession?.name, 'Session 2');
    expect(find.text('CLI agents'), findsNothing);
  });
}

class _MemoryMachineCredentialsStore extends MachineCredentialsStore {
  _MemoryMachineCredentialsStore(this.machine);

  final MachineCredential machine;
  String? _activeId;

  @override
  Future<List<MachineCredential>> readAll() async {
    _activeId ??= machine.id;
    return <MachineCredential>[machine];
  }

  @override
  Future<String?> readActiveId() async {
    _activeId ??= machine.id;
    return _activeId;
  }

  @override
  Future<void> setActive(String id) async {
    _activeId = id;
  }

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {}

  @override
  Future<void> delete(String id) async {
    if (_activeId == id) _activeId = null;
  }
}

class _SessionBackendClient extends BackendClient {
  int createdSessions = 0;
  final Map<String, List<AgentSession>> _sessions =
      <String, List<AgentSession>>{};
  final Map<String, String> _activeSessionIds = <String, String>{};

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async {
    return _listFor(agentKey);
  }

  @override
  Future<AgentSessionList> createSession(String agentKey, String name) async {
    createdSessions += 1;
    final DateTime now = DateTime.utc(2026, 1, 1, 0, 0, createdSessions);
    final AgentSession session = AgentSession(
      id: 'session-$createdSessions',
      name: name.isEmpty ? 'Session ${createdSessions + 1}' : name,
      createdAt: now,
      updatedAt: now,
    );
    final List<AgentSession> sessions = _sessionsFor(agentKey);
    sessions.insert(0, session);
    _activeSessionIds[agentKey] = session.id;
    return _listFor(agentKey);
  }

  @override
  Future<List<ChatMessage>> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    return const <ChatMessage>[];
  }

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async {
    return const <String, bool?>{};
  }

  @override
  Future<void> close() async {}

  List<AgentSession> _sessionsFor(String agentKey) {
    return _sessions.putIfAbsent(
      agentKey,
      () => <AgentSession>[
        AgentSession.fallback(),
      ],
    );
  }

  AgentSessionList _listFor(String agentKey) {
    final List<AgentSession> sessions =
        List<AgentSession>.unmodifiable(_sessionsFor(agentKey));
    return AgentSessionList(
      agentKey: agentKey,
      workdir: '/repo',
      activeSessionId: _activeSessionIds[agentKey] ?? AgentSession.defaultId,
      sessions: sessions,
    );
  }
}
