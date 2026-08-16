import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';

enum AgentLoginPhase {
  idle,
  starting,
  waitingForUrl,
  readyForCode,
  submitting,
  done,
  error,
}

class AgentLoginFlowController extends ChangeNotifier {
  AgentLoginFlowController({
    required Stream<BackendEvent> Function(String agentKey) startLogin,
    required Future<void> Function(String sessionId, String code) submitCode,
  })  : _startLogin = startLogin,
        _submitCode = submitCode;

  final Stream<BackendEvent> Function(String agentKey) _startLogin;
  final Future<void> Function(String sessionId, String code) _submitCode;

  StreamSubscription<BackendEvent>? _subscription;
  AgentLoginPhase _phase = AgentLoginPhase.idle;
  String? _sessionId;
  String? _url;
  String _output = '';
  String? _error;

  AgentLoginPhase get phase => _phase;
  String? get sessionId => _sessionId;
  String? get url => _url;
  String get output => _output;
  String? get error => _error;

  bool get canSubmitCode =>
      _sessionId != null &&
      _sessionId!.isNotEmpty &&
      (_phase == AgentLoginPhase.readyForCode ||
          _phase == AgentLoginPhase.waitingForUrl);

  Future<void> start(String agentKey) async {
    await _subscription?.cancel();
    _sessionId = null;
    _url = null;
    _output = '';
    _error = null;
    _setPhase(AgentLoginPhase.starting);
    try {
      _subscription = _startLogin(agentKey).listen(
        _handleEvent,
        onError: (Object err) {
          _error = _messageFor(err);
          _setPhase(AgentLoginPhase.error);
        },
      );
    } catch (err) {
      _error = _messageFor(err);
      _setPhase(AgentLoginPhase.error);
    }
  }

  Future<void> submitCode(String code) async {
    final String? id = _sessionId;
    if (id == null || id.isEmpty) {
      _error = 'Login session is not ready.';
      _setPhase(AgentLoginPhase.error);
      return;
    }
    _setPhase(AgentLoginPhase.submitting);
    try {
      await _submitCode(id, code.trim());
    } catch (err) {
      _error = _messageFor(err);
      _setPhase(AgentLoginPhase.error);
    }
  }

  void _handleEvent(BackendEvent event) {
    final String? eventSession = event.data['sessionId']?.toString();
    if (eventSession != null && eventSession.isNotEmpty) {
      _sessionId = eventSession;
    }
    switch (event.type) {
      case 'login_started':
        if (_phase == AgentLoginPhase.starting ||
            _phase == AgentLoginPhase.idle) {
          _setPhase(AgentLoginPhase.waitingForUrl);
        } else {
          notifyListeners();
        }
        break;
      case 'login_url':
        _url = event.data['url']?.toString();
        _setPhase(AgentLoginPhase.readyForCode);
        break;
      case 'login_output':
        final String text = event.data['text']?.toString() ?? '';
        if (text.isNotEmpty) {
          _output = (_output + text).trim();
          if (_output.length > 4000) {
            _output = _output.substring(_output.length - 4000);
          }
        }
        if (_phase == AgentLoginPhase.starting) {
          _setPhase(AgentLoginPhase.waitingForUrl);
        } else {
          notifyListeners();
        }
        break;
      case 'login_done':
        _setPhase(AgentLoginPhase.done);
        break;
      case 'login_error':
        _error = event.data['error']?.toString() ?? 'Login failed.';
        _setPhase(AgentLoginPhase.error);
        break;
      default:
        notifyListeners();
    }
  }

  void _setPhase(AgentLoginPhase value) {
    _phase = value;
    notifyListeners();
  }

  String _messageFor(Object err) {
    if (err is BackendException) return err.message;
    return err.toString();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
