import 'dart:async';

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
import 'package:relay/features/chat/bot_chat_screen.dart';
import 'package:relay/features/cli_agents/cli_agents_controller.dart';
import 'package:relay/features/machines/machine_credentials_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The hit sits near the start of a long conversation, so it can only show up on
// screen if the jump actually scrolled the (lazily built, reversed) list there.
const int _hitIndex = 3;
const int _messageCount = 60;
const String _term = 'deployment';

void main() {
  group('search chats jump', () {
    testWidgets('scrolls to the matched message and marks the term', (
      WidgetTester tester,
    ) async {
      final CliAgentsController agents = await _openChat(tester);

      // The conversation opens on the newest message, far from the hit.
      expect(_hitParagraph(), findsNothing);

      await _pickTheOnlyHit(tester);

      // The matched message is on screen…
      expect(_hitParagraph(), findsOneWidget);
      final Rect hit = tester.getRect(_hitParagraph());
      expect(hit.top, greaterThanOrEqualTo(0));
      expect(hit.bottom, lessThanOrEqualTo(844));

      // …with the search term marked inside it.
      expect(_markedTextIn(tester, _hitParagraph()), <String>[_term]);
      expect(agents.activeAgentKey, 'claude');

      // The mark is temporary: it clears itself shortly after.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(_markedTextIn(tester, _hitParagraph()), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('moves the active agent when the hit belongs to another one', (
      WidgetTester tester,
    ) async {
      final CliAgentsController agents = await _openChat(
        tester,
        hitAgentKey: 'codex',
      );
      expect(agents.activeAgentKey, 'claude');

      await _pickTheOnlyHit(tester);

      // Both the chat and the agent selection follow the hit; leaving the
      // agents controller behind would let the next context sync load the old
      // agent's conversation back over the one we just jumped to.
      expect(agents.activeAgentKey, 'codex');
      expect(_hitParagraph(), findsOneWidget);
      expect(_markedTextIn(tester, _hitParagraph()), <String>[_term]);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Builds the chat screen over a fake backend holding one long conversation.
Future<CliAgentsController> _openChat(
  WidgetTester tester, {
  String hitAgentKey = 'claude',
}) async {
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
  final BotChatController chatController = BotChatController(
    backendClient: _SearchBackendClient(hitAgentKey),
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
        home: BotChatScreen(
          agentsController: agentsController,
          chatController: chatController,
          machinesController: machinesController,
          settingsController: settingsController,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return agentsController;
}

Future<void> _pickTheOnlyHit(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.search_rounded));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    _term,
  );
  await tester.tap(find.widgetWithText(TextButton, 'Search chats'));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('…$_term…'));
  await tester.pumpAndSettle();
}

Finder _hitParagraph() {
  return find.byWidgetPredicate(
    (Widget widget) =>
        widget is RichText && widget.text.toPlainText().contains('#$_hitIndex '),
  );
}

List<String> _markedTextIn(WidgetTester tester, Finder finder) {
  final List<String> marked = <String>[];
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.text != null && span.style?.backgroundColor != null) {
      marked.add(span.text!);
    }
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      walk(child);
    }
  }

  for (final RichText text in tester.widgetList<RichText>(finder)) {
    walk(text.text);
  }
  return marked;
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

class _SearchBackendClient extends BackendClient {
  _SearchBackendClient(this.hitAgentKey);

  /// The agent whose history holds the match. Only that agent's conversation
  /// contains the searched term.
  final String hitAgentKey;

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async {
    return _list(agentKey);
  }

  @override
  Future<AgentSessionList> selectSession(
    String agentKey,
    String sessionId,
  ) async {
    return _list(agentKey);
  }

  @override
  Future<List<ChatMessage>> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    final bool holdsHit = agentKey == hitAgentKey;
    return <ChatMessage>[
      for (int i = 0; i < _messageCount; i += 1)
        ChatMessage(
          id: '$agentKey-msg-$i',
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          content: holdsHit && i == _hitIndex
              ? 'Note #$i about the $_term pipeline.'
              : 'Note #$i about something else entirely.',
          createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        ),
    ];
  }

  @override
  Future<List<ChatHistorySearchResult>> searchHistory(
    String query, {
    String? agentKey,
  }) async {
    return <ChatHistorySearchResult>[
      ChatHistorySearchResult(
        agentKey: hitAgentKey,
        sessionId: AgentSession.defaultId,
        sessionName: 'Main',
        snippet: '…$_term…',
        messageId: '$hitAgentKey-msg-$_hitIndex',
      ),
    ];
  }

  @override
  Future<Map<String, bool?>> fetchAuthStatus() async {
    return const <String, bool?>{};
  }

  @override
  Future<List<CliAgent>> fetchAgents() async => defaultCliAgents;

  // A stream that stays open: an empty one completes at once and the controller
  // then schedules a reconnect timer that outlives the test.
  final StreamController<BackendEvent> _events =
      StreamController<BackendEvent>.broadcast();

  @override
  Stream<BackendEvent> streamEvents() => _events.stream;

  @override
  Future<void> close() async {
    await _events.close();
  }

  AgentSessionList _list(String agentKey) {
    return AgentSessionList(
      agentKey: agentKey,
      workdir: '/repo',
      activeSessionId: AgentSession.defaultId,
      sessions: <AgentSession>[AgentSession.fallback()],
    );
  }
}
