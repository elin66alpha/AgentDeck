import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/features/chat/bot_chat_controller.dart';
import 'package:relay/features/filesystem/file_system_screen.dart';

void main() {
  testWidgets('set as work path is primary and swiping right goes up a folder', (
    WidgetTester tester,
  ) async {
    final _FsBackendClient backend = _FsBackendClient();
    final BotChatController chatController = BotChatController(
      backendClient: backend,
    );
    addTearDown(chatController.disposeController);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: FileSystemScreen(chatController: chatController),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(FilledButton, 'Set as work path'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'Upload file'), findsOneWidget);

    // A left swipe does nothing; a right swipe opens the parent folder.
    await tester.fling(find.text('src'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo/app');

    await tester.fling(find.text('src'), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo');
    expect(find.text('app'), findsOneWidget);
  });
}

class _FsBackendClient extends BackendClient {
  final List<String> browsed = <String>[];

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/repo/app');

  @override
  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) async {
    browsed.add(path);
    final bool atRoot = path == '/repo';
    final String child = atRoot ? 'app' : 'src';
    return FsListing(
      root: '/',
      path: path,
      absolutePath: path,
      parentPath: atRoot ? null : '/repo',
      entries: <FsEntry>[
        FsEntry(
          name: child,
          path: '$path/$child',
          absolutePath: '$path/$child',
          type: 'directory',
          size: 0,
          modifiedAt: '',
        ),
      ],
    );
  }

  @override
  Future<void> close() async {}
}
