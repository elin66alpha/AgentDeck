import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/features/chat/bot_chat_controller.dart';
import 'package:relay/features/quota/quota_usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows each quota source as soon as it answers', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _UsageBackendClient backendClient = _UsageBackendClient();
    final BotChatController chatController = BotChatController(
      backendClient: backendClient,
    );
    addTearDown(chatController.disposeController);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: QuotaUsageScreen(chatController: chatController),
        ),
      ),
    );

    // Both sources are queried separately, and the cards are up before either
    // answers instead of a full-screen spinner.
    expect(
      backendClient.pending.keys,
      unorderedEquals(<String>['claude', 'codex']),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Loading quota...'), findsNWidgets(2));

    backendClient.answer('claude');
    await tester.pump();
    expect(find.text('58% remaining'), findsOneWidget);
    expect(find.text('Loading quota...'), findsOneWidget);

    backendClient.answer('codex');
    await tester.pump();
    expect(find.text('58% remaining'), findsNWidgets(2));
    expect(find.text('Loading quota...'), findsNothing);
    expect(
      chatController.lastUsageReport?.agents.map((UsageAgent a) => a.key),
      <String>['claude', 'codex'],
    );
  });
}

class _UsageBackendClient extends BackendClient {
  final Map<String, Completer<UsageReport>> pending =
      <String, Completer<UsageReport>>{};

  @override
  Future<UsageReport> usageReport({String? source}) {
    return pending.putIfAbsent(source!, Completer<UsageReport>.new).future;
  }

  void answer(String source) {
    pending[source]!.complete(
      UsageReport.fromJson(<String, Object?>{
        'agents': <Object?>[
          <String, Object?>{
            'key': source,
            'label': _labels[source],
            'available': true,
            'quotas': <Object?>[
              <String, Object?>{'key': 'five_hour', 'remainingPercent': 58},
            ],
          },
        ],
      }),
    );
  }

  static const Map<String, String> _labels = <String, String>{
    'claude': 'Claude Code',
    'codex': 'Codex',
  };

  @override
  Future<void> close() async {}
}
