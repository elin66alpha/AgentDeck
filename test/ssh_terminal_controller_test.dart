import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/features/ssh/ssh_terminal_controller.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('latched Ctrl and Shift modify the next key and then release', () async {
    final StreamController<String> inputs = StreamController<String>();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.transform(WebSocketTransformer()).listen((WebSocket socket) {
      socket.add(jsonEncode(<String, Object?>{'type': 'ready'}));
      socket.listen((Object? raw) {
        final Map<String, Object?> message =
            jsonDecode(raw! as String) as Map<String, Object?>;
        if (message['type'] == 'input') inputs.add(message['data']! as String);
      });
    });
    final SshTerminalController controller = SshTerminalController(
      backend: _LocalBackendClient(Uri.parse('ws://127.0.0.1:${server.port}')),
    );
    addTearDown(() async {
      controller.dispose();
      await server.close(force: true);
    });
    final StreamIterator<String> received = StreamIterator<String>(
      inputs.stream,
    );
    Future<String> next() async {
      expect(await received.moveNext(), isTrue);
      return received.current;
    }

    final Completer<void> ready = Completer<void>();
    controller.addListener(() {
      if (controller.connected && !ready.isCompleted) ready.complete();
    });
    await controller.connect('machine-1');
    await ready.future;

    controller.toggleCtrl();
    controller.terminal.textInput('c');
    expect(await next(), '\x03');
    expect(controller.ctrlLatched, isFalse);

    controller.toggleShift();
    controller.terminal.textInput('a');
    expect(await next(), 'A');
    expect(controller.shiftLatched, isFalse);

    controller.toggleShift();
    controller.sendKey(TerminalKey.tab);
    expect(await next(), '\x1b[Z');

    controller.toggleCtrl();
    controller.sendKey(TerminalKey.arrowLeft);
    expect(await next(), '\x1b[1;5D');

    expect(controller.ctrlLatched, isFalse);

    controller.sendKey(TerminalKey.escape);
    expect(await next(), '\x1b');

    controller.terminal.textInput('c');
    expect(await next(), 'c');
  });
}

class _LocalBackendClient extends BackendClient {
  _LocalBackendClient(this.uri);

  final Uri uri;

  @override
  Future<Uri> terminalWebSocketUri({
    required int cols,
    required int rows,
  }) async {
    return uri;
  }
}
