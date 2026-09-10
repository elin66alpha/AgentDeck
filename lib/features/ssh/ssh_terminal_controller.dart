import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../core/backend/backend_client.dart';

enum SshTerminalStatus {
  disconnected,
  connecting,
  connected,
  exited,
  replaced,
  failed,
}

class SshTerminalController extends ChangeNotifier {
  SshTerminalController({required BackendClient backend}) : _backend = backend {
    terminal = _newTerminal();
  }

  final BackendClient _backend;
  final TerminalController terminalController = TerminalController();
  late Terminal terminal;

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  String? _machineId;
  String? _error;
  SshTerminalStatus _status = SshTerminalStatus.disconnected;
  bool _disposed = false;
  bool _wantsConnection = false;
  bool _hasConnected = false;
  int _generation = 0;
  bool _ctrlLatched = false;
  bool _shiftLatched = false;

  SshTerminalStatus get status => _status;
  String? get error => _error;
  bool get connected => _status == SshTerminalStatus.connected;
  bool get ctrlLatched => _ctrlLatched;
  bool get shiftLatched => _shiftLatched;

  Future<void> connect(String machineId) async {
    final String cleanMachineId = machineId.trim();
    if (cleanMachineId.isEmpty || _disposed) return;
    if (_machineId != cleanMachineId) {
      _machineId = cleanMachineId;
      _generation += 1;
      _hasConnected = false;
      _replaceTerminal();
      await _closeSocket();
      _setStatus(SshTerminalStatus.disconnected);
    }
    _wantsConnection = true;
    if (_status == SshTerminalStatus.connecting || connected) return;
    await _openSocket(_generation);
  }

  Future<void> retry() async {
    if (_machineId == null || _disposed) return;
    _wantsConnection = true;
    await _closeSocket();
    await _openSocket(++_generation);
  }

  void toggleCtrl() {
    _ctrlLatched = !_ctrlLatched;
    notifyListeners();
  }

  void toggleShift() {
    _shiftLatched = !_shiftLatched;
    notifyListeners();
  }

  /// Sends a key from the mobile key bar with the latched modifiers.
  void sendKey(TerminalKey key) {
    final bool ctrl = _ctrlLatched;
    final bool shift = _shiftLatched;
    _releaseModifiers();
    terminal.keyInput(key, ctrl: ctrl, shift: shift);
  }

  Terminal _newTerminal() {
    return Terminal(
      maxLines: 10000,
      onOutput: (String data) => _send(<String, Object?>{
        'type': 'input',
        'data': _applyModifiers(data),
      }),
      onResize: (int width, int height, int pixelWidth, int pixelHeight) {
        _send(<String, Object?>{
          'type': 'resize',
          'cols': width,
          'rows': height,
        });
      },
    );
  }

  void _replaceTerminal() {
    final int width = terminal.viewWidth;
    final int height = terminal.viewHeight;
    terminalController.clearSelection();
    terminal = _newTerminal()..resize(width, height);
    notifyListeners();
  }

  Future<void> _openSocket(int generation) async {
    if (_disposed || !_wantsConnection || generation != _generation) return;
    _reconnectTimer?.cancel();
    _error = null;
    _setStatus(SshTerminalStatus.connecting);

    if (_hasConnected) _replaceTerminal();
    final int cols = terminal.viewWidth;
    final int rows = terminal.viewHeight;
    WebSocketChannel? channel;
    try {
      final Uri uri = await _backend.terminalWebSocketUri(
        cols: cols,
        rows: rows,
      );
      if (_disposed || !_wantsConnection || generation != _generation) return;
      channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 15));
      if (_disposed || !_wantsConnection || generation != _generation) {
        await channel.sink.close();
        return;
      }
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (Object err, StackTrace stackTrace) {
          _handleDisconnect(channel!, generation, err);
        },
        onDone: () {
          _handleDisconnect(channel!, generation, null);
        },
        cancelOnError: false,
      );
    } catch (err) {
      if (_disposed || generation != _generation) return;
      await channel?.sink.close();
      if (channel != null && identical(_channel, channel)) _channel = null;
      _error = _errorText(err);
      _wantsConnection = false;
      _setStatus(SshTerminalStatus.failed);
    }
  }

  void _handleMessage(Object? raw) {
    if (raw is! String) return;
    late final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    switch (decoded['type']) {
      case 'output':
        final Object? data = decoded['data'];
        if (data is String && data.isNotEmpty) terminal.write(data);
      case 'ready':
        _hasConnected = true;
        _setStatus(SshTerminalStatus.connected);
        _send(<String, Object?>{
          'type': 'resize',
          'cols': terminal.viewWidth,
          'rows': terminal.viewHeight,
        });
      case 'exit':
        _wantsConnection = false;
        _setStatus(SshTerminalStatus.exited);
      case 'replaced':
        _wantsConnection = false;
        _setStatus(SshTerminalStatus.replaced);
      case 'error':
        _error = (decoded['message'] ?? 'SSH terminal failed.').toString();
        _wantsConnection = false;
        _setStatus(SshTerminalStatus.failed);
    }
  }

  void _handleDisconnect(
    WebSocketChannel channel,
    int generation,
    Object? error,
  ) {
    if (_disposed ||
        generation != _generation ||
        !identical(_channel, channel)) {
      return;
    }
    _channel = null;
    _subscription = null;
    if (_status == SshTerminalStatus.exited ||
        _status == SshTerminalStatus.replaced ||
        _status == SshTerminalStatus.failed) {
      return;
    }
    if (error != null) _error = _errorText(error);
    _setStatus(SshTerminalStatus.disconnected);
    if (!_wantsConnection || !_hasConnected) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 1), () {
      if (!_disposed && _wantsConnection) {
        unawaited(_openSocket(++_generation));
      }
    });
  }

  /// Soft keyboards can't hold Ctrl/Shift, so the latched modifiers apply to
  /// the next typed character (e.g. Ctrl then c sends ^C) and then release.
  String _applyModifiers(String data) {
    if ((!_ctrlLatched && !_shiftLatched) || data.length != 1) return data;
    String result = _shiftLatched ? data.toUpperCase() : data;
    if (_ctrlLatched) {
      // @, A-Z, [, \, ], ^ and _ map to the control codes 0x00-0x1F.
      final int code = result.toUpperCase().codeUnitAt(0);
      if (code >= 0x40 && code <= 0x5F) {
        result = String.fromCharCode(code - 0x40);
      }
    }
    _releaseModifiers();
    return result;
  }

  void _releaseModifiers() {
    if (!_ctrlLatched && !_shiftLatched) return;
    _ctrlLatched = false;
    _shiftLatched = false;
    notifyListeners();
  }

  void _send(Map<String, Object?> message) {
    if (!connected) return;
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {
      // The socket listener will move to reconnecting when it closes.
    }
  }

  void _setStatus(SshTerminalStatus value) {
    if (_status == value || _disposed) return;
    _status = value;
    notifyListeners();
  }

  String _errorText(Object err) {
    return err is BackendException ? err.message : err.toString();
  }

  Future<void> _closeSocket() async {
    _reconnectTimer?.cancel();
    final StreamSubscription<Object?>? subscription = _subscription;
    final WebSocketChannel? channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _wantsConnection = false;
    _reconnectTimer?.cancel();
    unawaited(_closeSocket());
    terminalController.dispose();
    super.dispose();
  }
}
