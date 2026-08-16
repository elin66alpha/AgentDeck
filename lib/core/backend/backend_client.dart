import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../i18n/app_strings.dart';
import '../models/agent_options.dart';
import '../models/agent_session.dart';
import '../models/chat_message.dart';
import '../models/cli_agent.dart';
import '../models/group.dart';
import '../models/machine_credential.dart';
import '../storage/device_id_store.dart';
import '../storage/machine_credentials_store.dart';
import '../storage/workdir_store.dart';
import '../util/format_bytes.dart';
import 'api_transport.dart';
import 'sse_codec.dart';

export 'api_transport.dart' show BackendException;
export 'sse_codec.dart' show BackendEvent;

List<ChatMessage> _decodeHistoryMessages(String body) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw BackendException('Backend returned non-JSON content.');
  }
  if (decoded is! Map) {
    throw BackendException('历史响应格式不正确。');
  }
  final List<Object?> raw = decoded['messages'] is List
      ? (decoded['messages'] as List).cast<Object?>()
      : const <Object?>[];
  return raw
      .whereType<Map>()
      .map((Map item) => ChatMessage.fromJson(item.cast<String, Object?>()))
      .toList(growable: false);
}

class BackendStatus {
  const BackendStatus({
    required this.workdir,
    required this.systemUptime,
    required this.processUptime,
    required this.agentTimeoutMs,
    required this.quotaWatch,
    required this.publicBaseUrl,
  });

  factory BackendStatus.fromJson(Map<String, Object?> json) {
    return BackendStatus(
      workdir: json['workdir'] as String? ?? '',
      systemUptime: json['systemUptime'] as String? ?? '',
      processUptime: json['processUptime'] as String? ?? '',
      agentTimeoutMs: json['agentTimeoutMs'] as int? ?? 0,
      quotaWatch: json['quotaWatch'] as bool? ?? false,
      publicBaseUrl: json['publicBaseUrl'] as String? ?? '',
    );
  }

  final String workdir;
  final String systemUptime;
  final String processUptime;
  final int agentTimeoutMs;
  final bool quotaWatch;
  final String publicBaseUrl;

  String toDisplayText(AppStrings strings) {
    final int timeoutMinutes = (agentTimeoutMs / 60000).round();
    final List<String> lines = <String>[
      strings.backendOnline,
      strings.workDirectoryLine(workdir),
      strings.systemUptimeLine(systemUptime),
      strings.processUptimeLine(processUptime),
      if (publicBaseUrl.isNotEmpty) strings.publicBaseUrlLine(publicBaseUrl),
      if (timeoutMinutes > 0) strings.taskTimeoutLine(timeoutMinutes),
      strings.quotaWatchLine(quotaWatch),
    ];
    return lines.join('\n');
  }
}

class DeviceToken {
  const DeviceToken({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.revoked,
    required this.current,
    required this.lastDeviceId,
    required this.lastDeviceName,
    this.revokedAt,
    this.lastUsedAt,
  });

  factory DeviceToken.fromJson(Map<String, Object?> json) {
    final String revokedAt = json['revokedAt'] as String? ?? '';
    final String lastUsedAt = json['lastUsedAt'] as String? ?? '';
    return DeviceToken(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      revoked: json['revoked'] as bool? ?? false,
      current: json['current'] as bool? ?? false,
      lastDeviceId: json['lastDeviceId'] as String? ?? '',
      lastDeviceName: json['lastDeviceName'] as String? ?? '',
      revokedAt: revokedAt.isEmpty ? null : revokedAt,
      lastUsedAt: lastUsedAt.isEmpty ? null : lastUsedAt,
    );
  }

  final String id;
  final String label;
  final String createdAt;
  final bool revoked;
  final bool current;
  final String lastDeviceId;
  final String lastDeviceName;
  final String? revokedAt;
  final String? lastUsedAt;

  DeviceToken copyWith({bool? revoked, String? revokedAt}) {
    return DeviceToken(
      id: id,
      label: label,
      createdAt: createdAt,
      revoked: revoked ?? this.revoked,
      current: current,
      lastDeviceId: lastDeviceId,
      lastDeviceName: lastDeviceName,
      revokedAt: revokedAt ?? this.revokedAt,
      lastUsedAt: lastUsedAt,
    );
  }
}

class BackendDiagnostics {
  const BackendDiagnostics(this.json);

  factory BackendDiagnostics.fromJson(Map<String, Object?> json) {
    return BackendDiagnostics(json);
  }

  final Map<String, Object?> json;

  Map<String, Object?> _map(String key) =>
      (json[key] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};

  String _string(Map<String, Object?> map, String key) =>
      map[key]?.toString() ?? '';

  int _int(Map<String, Object?> map, String key) =>
      (map[key] as num?)?.toInt() ?? 0;

  bool _bool(Map<String, Object?> map, String key) =>
      map[key] as bool? ?? false;

  String toDisplayText(AppStrings strings) {
    final Map<String, Object?> server = _map('server');
    final Map<String, Object?> runtime = _map('runtime');
    final Map<String, Object?> auth = _map('auth');
    final Map<String, Object?> workdir = _map('workdir');
    final Map<String, Object?> currentWorkdir =
        (workdir['current'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final Map<String, Object?> defaultWorkdir =
        (workdir['default'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final List<Object?> agents =
        json['agents'] is List ? (json['agents'] as List).cast<Object?>() : [];
    final List<Object?> storage = json['storage'] is List
        ? (json['storage'] as List).cast<Object?>()
        : [];

    final int timeoutMinutes = (_int(server, 'agentTimeoutMs') / 60000).round();
    final List<String> lines = <String>[
      strings.backendOnline,
      strings.diagnosticsGeneratedLine(json['createdAt']?.toString() ?? ''),
      strings.diagnosticsRuntimeLine(
        _string(server, 'platform'),
        _string(server, 'arch'),
        _string(server, 'node'),
      ),
      strings.diagnosticsListenLine(
        _string(server, 'host'),
        _int(server, 'port'),
      ),
      if (_string(server, 'publicBaseUrl').isNotEmpty)
        strings.publicBaseUrlLine(_string(server, 'publicBaseUrl')),
      strings.workDirectoryLine(_string(currentWorkdir, 'dir')),
      strings.diagnosticsWorkdirLine(
        exists: _bool(currentWorkdir, 'exists'),
        writable: _bool(currentWorkdir, 'writable'),
      ),
      strings.diagnosticsDefaultWorkdirLine(_string(defaultWorkdir, 'dir')),
      if (timeoutMinutes > 0) strings.taskTimeoutLine(timeoutMinutes),
      strings.quotaWatchLine(_bool(server, 'quotaWatch')),
      strings.diagnosticsTransferLimitLine(
        formatBytes(_int(server, 'maxUploadBytes')),
        formatBytes(_int(server, 'maxDownloadBytes')),
      ),
      strings.diagnosticsTokenLine(
        configured: _bool(auth, 'configured'),
        active: _int(auth, 'active'),
        total: _int(auth, 'total'),
      ),
      strings.diagnosticsRequestLine(
        active: _int(runtime, 'activeRequests'),
        running: _int(runtime, 'runningScopes'),
        queued: _int(runtime, 'queuedScopes'),
        sse: _int(runtime, 'sseClients'),
      ),
      strings.diagnosticsWebBuildLine(
        ((server['webBuild'] as Map?)?.cast<String, Object?>() ??
                const <String, Object?>{})['indexExists'] ==
            true,
      ),
      '',
      strings.diagnosticsAgentsHeader,
      for (final Object? item in agents)
        _agentLine(strings, (item as Map?)?.cast<String, Object?>()),
      '',
      strings.diagnosticsStorageHeader,
      for (final Object? item in storage)
        _storageLine(strings, (item as Map?)?.cast<String, Object?>()),
    ];
    return lines.where((String line) => line.trim().isNotEmpty).join('\n');
  }

  String _agentLine(AppStrings strings, Map<String, Object?>? item) {
    final Map<String, Object?> agent = item ?? const <String, Object?>{};
    final Map<String, Object?> cli =
        (agent['cli'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return strings.diagnosticsAgentLine(
      agent['label']?.toString() ?? agent['key']?.toString() ?? '',
      available: cli['available'] == true,
      loggedIn: agent['loggedIn'] as bool?,
      path: cli['path']?.toString() ?? '',
    );
  }

  String _storageLine(AppStrings strings, Map<String, Object?>? item) {
    final Map<String, Object?> file = item ?? const <String, Object?>{};
    return strings.diagnosticsStorageLine(
      file['name']?.toString() ?? '',
      exists: file['exists'] == true,
      writable: file['writable'] == true,
      size: formatBytes((file['sizeBytes'] as num?)?.toInt() ?? 0),
    );
  }
}

class ChatReply {
  const ChatReply({
    required this.requestId,
    required this.agentKey,
    required this.agentLabel,
    required this.content,
    this.segments = const <MessageSegment>[],
  });

  final String requestId;
  final String agentKey;
  final String agentLabel;
  final String content;
  final List<MessageSegment> segments;
}

List<MessageSegment> _segmentsFromMessage(Map<String, Object?> message) {
  final Object? raw = message['segments'];
  if (raw is! List) return const <MessageSegment>[];
  return raw
      .whereType<Map>()
      .map((Map e) => MessageSegment.fromJson(e.cast<String, Object?>()))
      .toList(growable: false);
}

class WorkdirInfo {
  const WorkdirInfo({
    required this.dir,
    this.exists = true,
    this.isDirectory = true,
    this.busy = false,
    this.created = false,
  });

  factory WorkdirInfo.fromJson(Map<String, Object?> json) {
    return WorkdirInfo(
      dir: json['dir'] as String? ?? '',
      exists: json['exists'] as bool? ?? true,
      isDirectory: json['isDirectory'] as bool? ?? true,
      busy: json['busy'] as bool? ?? false,
      created: json['created'] as bool? ?? false,
    );
  }

  final String dir;
  final bool exists;
  final bool isDirectory;
  final bool busy;
  final bool created;
}

class AgentSessionList {
  const AgentSessionList({
    required this.agentKey,
    required this.workdir,
    required this.activeSessionId,
    required this.sessions,
  });

  factory AgentSessionList.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> agent =
        (json['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final List<Object?> rawSessions = json['sessions'] is List
        ? (json['sessions'] as List).cast<Object?>()
        : const <Object?>[];
    final List<AgentSession> sessions = rawSessions
        .whereType<Map>()
        .map((Map item) => AgentSession.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
    final String activeSessionId = json['activeSessionId'] as String? ??
        (sessions.isNotEmpty ? sessions.first.id : AgentSession.defaultId);
    return AgentSessionList(
      agentKey: agent['key'] as String? ?? '',
      workdir: json['workdir'] as String? ?? '',
      activeSessionId: activeSessionId,
      sessions:
          sessions.isEmpty ? <AgentSession>[AgentSession.fallback()] : sessions,
    );
  }

  final String agentKey;
  final String workdir;
  final String activeSessionId;
  final List<AgentSession> sessions;

  AgentSession get activeSession {
    for (final AgentSession session in sessions) {
      if (session.id == activeSessionId) return session;
    }
    return sessions.isNotEmpty ? sessions.first : AgentSession.fallback();
  }
}

class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.absolutePath,
    required this.type,
    required this.size,
    required this.modifiedAt,
  });

  factory FsEntry.fromJson(Map<String, Object?> json) {
    return FsEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      absolutePath: json['absolutePath'] as String? ?? '',
      type: json['type'] as String? ?? 'other',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt: json['modifiedAt'] as String? ?? '',
    );
  }

  final String name;
  final String path;
  final String absolutePath;
  final String type;
  final int size;
  final String modifiedAt;

  bool get isDirectory => type == 'directory';
  bool get isFile => type == 'file';
}

class FsListing {
  const FsListing({
    required this.root,
    required this.path,
    required this.absolutePath,
    required this.entries,
    this.parentPath,
  });

  factory FsListing.fromJson(Map<String, Object?> json) {
    final List<Object?> rawEntries = json['entries'] is List
        ? (json['entries'] as List).cast<Object?>()
        : const <Object?>[];
    return FsListing(
      root: json['root'] as String? ?? '',
      path: json['path'] as String? ?? '',
      absolutePath: json['absolutePath'] as String? ?? '',
      parentPath: json['parentPath'] as String?,
      entries: rawEntries
          .whereType<Map>()
          .map((Map entry) => FsEntry.fromJson(entry.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  final String root;
  final String path;
  final String absolutePath;
  final String? parentPath;
  final List<FsEntry> entries;
}

/// An in-progress file download: response metadata plus the live byte stream.
/// The caller consumes [bytes] straight to its destination (a file on native, a
/// blob on web) so a large download is never buffered whole in memory.
class FsDownloadStream {
  const FsDownloadStream({
    required this.fileName,
    required this.total,
    required this.bytes,
  });

  final String fileName;

  /// Total bytes when the server announced a Content-Length, else null.
  final int? total;

  final Stream<List<int>> bytes;
}

class ChatHistorySearchResult {
  const ChatHistorySearchResult({
    required this.agentKey,
    required this.sessionId,
    required this.sessionName,
    required this.snippet,
    required this.messageId,
  });

  factory ChatHistorySearchResult.fromJson(Map<String, Object?> json) {
    return ChatHistorySearchResult(
      agentKey: json['agentKey'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      sessionName: json['sessionName'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      messageId: json['messageId'] as String? ?? '',
    );
  }

  final String agentKey;
  final String sessionId;
  final String sessionName;
  final String snippet;
  final String messageId;
}

class ConversationExport {
  const ConversationExport({required this.fileName, required this.markdown});

  factory ConversationExport.fromJson(Map<String, Object?> json) {
    return ConversationExport(
      fileName: json['fileName'] as String? ?? 'relay-conversation.md',
      markdown: json['markdown'] as String? ?? '',
    );
  }

  final String fileName;
  final String markdown;
}

class PushConfig {
  const PushConfig({required this.enabled, required this.publicKey});

  factory PushConfig.fromJson(Map<String, Object?> json) {
    return PushConfig(
      enabled: json['enabled'] as bool? ?? false,
      publicKey: json['publicKey'] as String? ?? '',
    );
  }

  final bool enabled;
  final String publicKey;
}

class UsageQuota {
  const UsageQuota({
    required this.key,
    required this.label,
    required this.remainingPercent,
    required this.resetsAt,
    this.expired = false,
  });

  factory UsageQuota.fromJson(Map<String, Object?> json) {
    return UsageQuota(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      remainingPercent: (json['remainingPercent'] as num?)?.toDouble(),
      resetsAt: json['resetsAt'] as String?,
      expired: json['expired'] as bool? ?? false,
    );
  }

  final String key;
  final String label;
  final double? remainingPercent;
  final String? resetsAt;

  /// True when this is a stale cached bucket whose reset window has already
  /// passed, so [remainingPercent] no longer reflects reality and the UI should
  /// show a "window reset, awaiting refresh" hint instead of the old number.
  final bool expired;
}

class UsageAgent {
  const UsageAgent({
    required this.key,
    required this.label,
    required this.available,
    required this.stale,
    required this.quotas,
    this.detail = '',
    this.asOf,
    this.error,
    this.unavailableReason,
  });

  factory UsageAgent.fromJson(Map<String, Object?> json) {
    final List<Object?> rawQuotas = json['quotas'] is List
        ? (json['quotas'] as List).cast<Object?>()
        : const <Object?>[];
    return UsageAgent(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      available: json['available'] as bool? ?? false,
      stale: json['stale'] as bool? ?? false,
      detail: json['detail'] as String? ?? '',
      asOf: json['asOf'] as String?,
      error: json['error'] as String?,
      unavailableReason: json['unavailableReason'] as String?,
      quotas: rawQuotas
          .whereType<Map>()
          .map((Map q) => UsageQuota.fromJson(q.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  final String key;
  final String label;
  final bool available;
  final bool stale;
  final String detail;
  final String? asOf;
  final String? error;
  final String? unavailableReason;
  final List<UsageQuota> quotas;
}

class UsageReport {
  const UsageReport({
    required this.createdAt,
    required this.agents,
    required this.hasStale,
  });

  factory UsageReport.fromJson(Map<String, Object?> json) {
    final List<Object?> rawAgents = json['agents'] is List
        ? (json['agents'] as List).cast<Object?>()
        : const <Object?>[];
    return UsageReport(
      createdAt: json['createdAt'] as String? ?? '',
      hasStale: json['hasStale'] as bool? ?? false,
      agents: rawAgents
          .whereType<Map>()
          .map(
            (Map agent) => UsageAgent.fromJson(agent.cast<String, Object?>()),
          )
          .toList(growable: false),
    );
  }

  final String createdAt;
  final List<UsageAgent> agents;
  final bool hasStale;
}

class QuotaSchedule {
  const QuotaSchedule({
    required this.id,
    required this.sourceKey,
    required this.agentKey,
    required this.sessionId,
    required this.workdir,
    required this.prompt,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.sessionName = '',
    this.targetResetsAt,
    this.sentAt,
    this.error,
  });

  factory QuotaSchedule.fromJson(Map<String, Object?> json) {
    return QuotaSchedule(
      id: json['id'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      agentKey: json['agentKey'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      sessionName: json['sessionName'] as String? ?? '',
      workdir: json['workdir'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      targetResetsAt: json['targetResetsAt'] as String?,
      status: json['status'] as String? ?? 'pending',
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      sentAt: json['sentAt'] as String?,
      error: json['error'] as String?,
    );
  }

  final String id;
  final String sourceKey;
  final String agentKey;
  final String sessionId;
  final String sessionName;
  final String workdir;
  final String prompt;
  final String? targetResetsAt;
  final String status;
  final String createdAt;
  final String updatedAt;
  final String? sentAt;
  final String? error;

  bool get canCancel => status == 'pending';
}

class GroupHistory {
  const GroupHistory({required this.group, required this.messages});

  final ChatGroup group;
  final List<ChatMessage> messages;
}

class ChatStreamHandle {
  ChatStreamHandle({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  bool _closed = false;

  bool get closed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

class BackendClient {
  BackendClient({
    MachineCredentialsStore? credentialsStore,
    DeviceIdStore? deviceIdStore,
    WorkdirStore? workdirStore,
    http.Client? httpClient,
  }) : _transport = ApiTransport(
          credentialsStore: credentialsStore,
          deviceIdStore: deviceIdStore,
          workdirStore: workdirStore,
          httpClient: httpClient,
        );

  final ApiTransport _transport;
  http.Client get _httpClient => _transport.httpClient;

  /// This device's current work directory, or null when it has not chosen one
  /// (the backend then uses its default).
  Future<String?> currentWorkdir() => _transport.currentWorkdir();

  Future<void> close() async {
    _transport.close();
  }

  Future<bool> health({Duration timeout = const Duration(seconds: 20)}) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/health',
      timeout: timeout,
    );
    return decoded is Map && decoded['ok'] == true;
  }

  Future<bool> healthFor(
    MachineCredential credential, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Object? decoded = await _requestJsonWithCredential(
      credential,
      'GET',
      '/api/health',
      timeout: timeout,
    );
    return decoded is Map && decoded['ok'] == true;
  }

  Future<Uri> terminalWebSocketUri({
    required int cols,
    required int rows,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Object? decoded = await _requestJson(
      'POST',
      '/api/terminal/ticket',
      body: <String, Object?>{'cols': cols, 'rows': rows},
      timeout: const Duration(seconds: 15),
    );
    if (decoded is! Map || decoded['ticket'] is! String) {
      throw BackendException('Invalid SSH terminal ticket response.');
    }
    final String ticket = (decoded['ticket'] as String).trim();
    if (ticket.isEmpty) {
      throw BackendException('The SSH terminal ticket is empty.');
    }
    final Uri endpoint = _uri(credential, '/api/terminal/connect');
    return endpoint.replace(
      scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
      queryParameters: <String, String>{'ticket': ticket},
    );
  }

  Future<BackendStatus> status({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/status',
      timeout: timeout,
    );
    if (decoded is! Map) {
      throw BackendException('Invalid backend status response.');
    }
    return BackendStatus.fromJson(decoded.cast<String, Object?>());
  }

  Future<BackendDiagnostics> diagnostics({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/diagnostics',
      timeout: timeout,
    );
    if (decoded is! Map) {
      throw BackendException('Invalid backend diagnostics response.');
    }
    return BackendDiagnostics.fromJson(decoded.cast<String, Object?>());
  }

  Future<List<DeviceToken>> deviceTokens() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/tokens',
      timeout: const Duration(seconds: 20),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid token list response.');
    }
    final List<Object?> raw = decoded['tokens'] is List
        ? (decoded['tokens'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => DeviceToken.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<void> revokeDeviceToken(String id) async {
    await _requestJson(
      'POST',
      '/api/tokens/${Uri.encodeComponent(id)}/revoke',
      timeout: const Duration(seconds: 20),
    );
  }

  Future<void> deleteDeviceToken(String id) async {
    await _requestJson(
      'POST',
      '/api/tokens/${Uri.encodeComponent(id)}/delete',
      timeout: const Duration(seconds: 20),
    );
  }

  Future<PushConfig> pushConfig() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/push/config',
      timeout: const Duration(seconds: 15),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid push config response.');
    }
    return PushConfig.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> subscribePush(
    String subscriptionJson,
    String lang, {
    required bool quotaPushEnabled,
    required bool taskPushEnabled,
  }) async {
    final Object? subscription = jsonDecode(subscriptionJson);
    await _requestJson(
      'POST',
      '/api/push/subscribe',
      body: <String, Object?>{
        'subscription': subscription,
        'lang': lang,
        'quota': quotaPushEnabled,
        'task': taskPushEnabled,
      },
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> unsubscribePush(String endpoint) async {
    await _requestJson(
      'POST',
      '/api/push/unsubscribe',
      body: <String, Object?>{'endpoint': endpoint},
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> registerFcmToken(
    String token,
    String lang, {
    required bool quotaPushEnabled,
    required bool taskPushEnabled,
  }) async {
    await _requestJson(
      'POST',
      '/api/push/fcm/register',
      body: <String, Object?>{
        'token': token,
        'lang': lang,
        'quota': quotaPushEnabled,
        'task': taskPushEnabled,
      },
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> unregisterFcmToken(String token) async {
    await _requestJson(
      'POST',
      '/api/push/fcm/unregister',
      body: <String, Object?>{'token': token},
      timeout: const Duration(seconds: 15),
    );
  }

  Future<ChatReply> sendMessage({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    void Function(BackendEvent event)? onEvent,
    ChatStreamHandle? streamHandle,
    void Function()? onStreamStarted,
  }) async {
    if (onEvent != null) {
      return _sendMessageStreamed(
        agentKey: agentKey,
        sessionId: sessionId,
        prompt: prompt,
        requestId: requestId,
        onEvent: onEvent,
        streamHandle: streamHandle,
        onStreamStarted: onStreamStarted,
      );
    }
    final Object? decoded = await _requestJson(
      'POST',
      '/api/chat',
      body: <String, Object?>{
        'agent': agentKey,
        'sessionId': sessionId,
        'prompt': prompt,
        'requestId': requestId,
      },
      timeout: const Duration(minutes: 65),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid backend chat response.');
    }
    final Map<String, Object?> json = decoded.cast<String, Object?>();
    final Map<String, Object?> agent =
        (json['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final Map<String, Object?> message =
        (json['message'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return ChatReply(
      requestId: json['requestId'] as String? ?? requestId,
      agentKey: agent['key'] as String? ?? agentKey,
      agentLabel: agent['label'] as String? ?? agentKey,
      content: message['content'] as String? ?? '',
      segments: _segmentsFromMessage(message),
    );
  }

  Future<void> compressConversation({
    required String agentKey,
    required String sessionId,
    required String requestId,
  }) async {
    await _requestJson(
      'POST',
      '/api/chat',
      body: <String, Object?>{
        'agent': agentKey,
        'sessionId': sessionId,
        'prompt': '/compact',
        'requestId': requestId,
        'recordHistory': false,
      },
      timeout: const Duration(minutes: 65),
    );
  }

  Future<ChatReply> _sendMessageStreamed({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    required void Function(BackendEvent event) onEvent,
    ChatStreamHandle? streamHandle,
    void Function()? onStreamStarted,
    String path = '/api/chat',
  }) async {
    final ChatStreamHandle handle = streamHandle ?? ChatStreamHandle();
    final MachineCredential credential = await _requireCredential();
    final http.Request request = http.Request(
      'POST',
      _uri(credential, path),
    );
    request.headers.addAll(
      await _headers(credential, accept: 'text/event-stream'),
    );
    request.body = jsonEncode(<String, Object?>{
      'agent': agentKey,
      'sessionId': sessionId,
      'prompt': prompt,
      'requestId': requestId,
    });

    try {
      final http.StreamedResponse response = await handle._client
          .send(request)
          .timeout(const Duration(minutes: 65));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String text = await response.stream.bytesToString();
        throw _exceptionFor(response.statusCode, text);
      }
      onStreamStarted?.call();

      ChatReply? reply;
      BackendException? streamError;
      try {
        await for (final BackendEvent event in decodeSse(
          response.stream,
        ).timeout(const Duration(minutes: 65))) {
          if (event.type == 'ready' || event.type == 'heartbeat') continue;
          onEvent(event);
          if (event.type == 'agent_done') {
            reply = _chatReplyFromStreamDone(event.data, requestId, agentKey);
          } else if (event.type == 'agent_cancelled') {
            streamError = BackendException(
              'request cancelled',
              status: 499,
              code: 'AGENT_CANCELLED',
            );
          } else if (event.type == 'agent_error') {
            final String? code = event.data['code'] as String?;
            streamError = BackendException(
              event.data['error'] as String? ?? 'Agent stream failed.',
              status: code == 'NOT_LOGGED_IN' ? 424 : 500,
              code: code,
            );
          }
        }
      } on http.ClientException {
        // The app was backgrounded/closed and the OS tore down the socket while
        // the backend keeps running the turn. A distinct code lets the caller
        // reattach to the still-running turn instead of marking it failed.
        throw BackendException(
          'Lost the connection to the agent stream.',
          code: 'STREAM_DISCONNECTED',
        );
      } on TimeoutException {
        throw BackendException(
          'The agent stream stalled.',
          code: 'STREAM_DISCONNECTED',
        );
      }
      if (streamError != null) throw streamError;
      if (reply == null) {
        // The stream ended without a terminal agent_done — the turn may still be
        // running on the backend. A distinct code lets the caller reattach.
        throw BackendException(
          'Agent stream ended without a final response.',
          code: 'STREAM_INCOMPLETE',
        );
      }
      return reply;
    } finally {
      handle.close();
    }
  }

  Future<void> cancelMessage(String requestId) async {
    await _requestJson(
      'POST',
      '/api/chat/cancel',
      body: <String, Object?>{'requestId': requestId},
      timeout: const Duration(seconds: 10),
    );
  }

  Future<UsageReport> usageReport() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/usage',
      timeout: const Duration(seconds: 45),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid usage response.');
    }
    return UsageReport.fromJson(decoded.cast<String, Object?>());
  }

  Future<List<QuotaSchedule>> quotaSchedules() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/quota-schedules',
      timeout: const Duration(seconds: 20),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid quota schedules response.');
    }
    final List<Object?> raw = decoded['schedules'] is List
        ? (decoded['schedules'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => QuotaSchedule.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<QuotaSchedule> createQuotaSchedule({
    required String sourceKey,
    required String agentKey,
    required String sessionId,
    required String prompt,
    String? targetResetsAt,
    bool replaceExisting = false,
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/quota-schedules',
      body: <String, Object?>{
        'sourceKey': sourceKey,
        'agent': agentKey,
        'sessionId': sessionId,
        'prompt': prompt,
        if (replaceExisting) 'replaceExisting': true,
        if (targetResetsAt != null) 'targetResetsAt': targetResetsAt,
      },
      timeout: const Duration(seconds: 20),
    );
    if (decoded is! Map || decoded['schedule'] is! Map) {
      throw BackendException('Invalid quota schedule response.');
    }
    return QuotaSchedule.fromJson(
      (decoded['schedule'] as Map).cast<String, Object?>(),
    );
  }

  Future<void> cancelQuotaSchedule(String id) async {
    await _requestJson(
      'POST',
      '/api/quota-schedules/cancel',
      body: <String, Object?>{'id': id},
      timeout: const Duration(seconds: 20),
    );
  }

  Future<AgentSessionList> fetchSessions(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/sessions?agent=${Uri.encodeQueryComponent(agentKey)}',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid sessions response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  Future<AgentSessionList> createSession(String agentKey, String name) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions',
      body: <String, Object?>{'agent': agentKey, 'name': name},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid session creation response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  Future<AgentSessionList> selectSession(
    String agentKey,
    String sessionId,
  ) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions/active',
      body: <String, Object?>{'agent': agentKey, 'sessionId': sessionId},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid session selection response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  Future<AgentSessionList> deleteSession(
    String agentKey,
    String sessionId,
  ) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions/delete',
      body: <String, Object?>{'agent': agentKey, 'sessionId': sessionId},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid session delete response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  /// Fetches the stored conversation for one agent session so the app can show
  /// the previous chat on reopen without persisting anything locally.
  Future<List<ChatMessage>> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    final String query = 'agent=${Uri.encodeQueryComponent(agentKey)}'
        '&sessionId=${Uri.encodeQueryComponent(sessionId)}';
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(credential, '/api/history?$query');
    late final http.Response response;
    try {
      response = await _httpClient
          .get(uri, headers: await _headers(credential))
          .timeout(const Duration(seconds: 20));
    } on BackendException {
      rethrow;
    } on TimeoutException {
      throw BackendException(
        'Timed out connecting to ${uri.host}.',
        code: 'NETWORK_TIMEOUT',
      );
    } on http.ClientException catch (err) {
      throw _networkExceptionFor(err, uri);
    } catch (err) {
      throw _networkExceptionFor(err, uri);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, response.body);
    }
    if (!kIsWeb && response.body.length > 256 * 1024) {
      return compute(_decodeHistoryMessages, response.body);
    }
    return _decodeHistoryMessages(response.body);
  }

  // --- Group chat (multi-agent) ---------------------------------------------

  List<ChatGroup> _groupsFrom(Object? decoded) {
    if (decoded is! Map) throw BackendException('Invalid groups response.');
    final List<Object?> raw = decoded['groups'] is List
        ? (decoded['groups'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => ChatGroup.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<List<ChatGroup>> fetchGroups() async {
    return _groupsFrom(await _requestJson('GET', '/api/groups'));
  }

  Future<List<ChatGroup>> createGroup(
    String name,
    List<String> members, {
    String workdir = '',
    Map<String, Map<String, String>> configs =
        const <String, Map<String, String>>{},
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/groups',
      body: <String, Object?>{
        'name': name,
        'members': members,
        if (workdir.isNotEmpty) 'workdir': workdir,
        if (configs.isNotEmpty) 'configs': configs,
      },
    );
    return _groupsFrom(decoded);
  }

  Future<List<ChatGroup>> setGroupMembers(
    String groupId,
    List<String> members, {
    Map<String, Map<String, String>> configs =
        const <String, Map<String, String>>{},
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/groups/members',
      body: <String, Object?>{
        'groupId': groupId,
        'members': members,
        if (configs.isNotEmpty) 'configs': configs,
      },
    );
    return _groupsFrom(decoded);
  }

  Future<List<ChatGroup>> deleteGroup(String groupId) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/groups/delete',
      body: <String, Object?>{'groupId': groupId},
    );
    return _groupsFrom(decoded);
  }

  Future<GroupHistory> fetchGroupHistory(String groupId) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/group/history?groupId=${Uri.encodeQueryComponent(groupId)}',
    );
    if (decoded is! Map) throw BackendException('Invalid group history.');
    final List<Object?> raw = decoded['messages'] is List
        ? (decoded['messages'] as List).cast<Object?>()
        : const <Object?>[];
    return GroupHistory(
      group: ChatGroup.fromJson(
        (decoded['group'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      ),
      messages: raw
          .whereType<Map>()
          .map((Map item) => ChatMessage.fromJson(item.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  /// Post a human message to a group. Sent as plain JSON (not SSE): the per-agent
  /// turn deltas are mirrored to every device on the shared `/api/events` stream,
  /// tagged with `groupId`, so the UI renders from there. Awaiting this resolves
  /// when the whole round (every summoned member) finishes.
  Future<void> sendGroupMessage({
    required String groupId,
    required String prompt,
    required String requestId,
  }) async {
    await _requestJson(
      'POST',
      '/api/group/chat',
      body: <String, Object?>{
        'groupId': groupId,
        'prompt': prompt,
        'requestId': requestId,
      },
      timeout: const Duration(minutes: 65),
    );
  }

  Future<void> cancelGroupMessage(String requestId) async {
    await _requestJson(
      'POST',
      '/api/group/chat/cancel',
      body: <String, Object?>{'requestId': requestId},
    );
  }

  Future<void> clearGroup(String groupId) async {
    await _requestJson(
      'POST',
      '/api/group/clear',
      body: <String, Object?>{'groupId': groupId},
    );
  }

  Future<List<ChatHistorySearchResult>> searchHistory(
    String query, {
    String? agentKey,
  }) async {
    final String trimmed = query.trim();
    final String path =
        '/api/history/search?q=${Uri.encodeQueryComponent(trimmed)}'
        '${agentKey == null || agentKey.isEmpty ? '' : '&agent=${Uri.encodeQueryComponent(agentKey)}'}';
    final Object? decoded = await _requestJson('GET', path);
    if (decoded is! Map) {
      throw BackendException('Invalid search response.');
    }
    final List<Object?> raw = decoded['matches'] is List
        ? (decoded['matches'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map(
          (Map item) =>
              ChatHistorySearchResult.fromJson(item.cast<String, Object?>()),
        )
        .toList(growable: false);
  }

  Future<ConversationExport> exportHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    final String query = 'agent=${Uri.encodeQueryComponent(agentKey)}'
        '&sessionId=${Uri.encodeQueryComponent(sessionId)}';
    final Object? decoded = await _requestJson(
      'GET',
      '/api/history/export?$query',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid history export response.');
    }
    return ConversationExport.fromJson(decoded.cast<String, Object?>());
  }

  /// Best-effort login state per agent so the app can warn before sending a
  /// message. Maps agentKey -> loggedIn, where the value is true/false when the
  /// backend can read the CLI's credentials, or null when it cannot tell.
  Future<Map<String, bool?>> fetchAuthStatus() async {
    final Object? decoded = await _requestJson('GET', '/api/auth/status');
    final Map<String, bool?> result = <String, bool?>{};
    if (decoded is Map && decoded['agents'] is List) {
      for (final Object? item in (decoded['agents'] as List)) {
        if (item is! Map) continue;
        final String key = item['key'] as String? ?? '';
        if (key.isEmpty) continue;
        final Object? loggedIn = item['loggedIn'];
        result[key] = loggedIn is bool ? loggedIn : null;
      }
    }
    return result;
  }

  /// The agents the backend host knows about, including install/auth status.
  Future<List<CliAgent>> fetchAgents() async {
    final Object? decoded = await _requestJson('GET', '/api/agents');
    if (decoded is! Map) {
      throw BackendException('Invalid agents response.');
    }
    final List<Object?> raw = decoded['agents'] is List
        ? (decoded['agents'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => CliAgent.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Stream<BackendEvent> streamAgentLogin(String agentKey) async* {
    final MachineCredential credential = await _requireCredential();
    final http.Request request = http.Request(
      'GET',
      _uri(
        credential,
        '/api/agent-auth/login/start?agent=${Uri.encodeQueryComponent(agentKey)}',
      ),
    );
    request.headers.addAll(
      await _headers(credential, accept: 'text/event-stream'),
    );

    final http.StreamedResponse response = await _httpClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String text = await response.stream.bytesToString();
      throw _exceptionFor(response.statusCode, text);
    }

    yield* decodeSse(response.stream);
  }

  Future<void> submitAgentLoginCode({
    required String sessionId,
    required String code,
  }) async {
    await _requestJson(
      'POST',
      '/api/agent-auth/login/code',
      body: <String, Object?>{'sessionId': sessionId, 'code': code},
      timeout: const Duration(seconds: 20),
    );
  }

  /// Catalog of selectable model/effort/permission/fast options for an agent.
  Future<AgentOptionsCatalog> fetchAgentOptions(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/agent-options?agent=${Uri.encodeQueryComponent(agentKey)}',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid agent options response.');
    }
    return AgentOptionsCatalog.fromJson(decoded.cast<String, Object?>());
  }

  /// Current model/effort/permission/fast selection for the workdir+agent
  /// scope.
  Future<AgentSettings> fetchAgentSettings(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/agent-settings?agent=${Uri.encodeQueryComponent(agentKey)}',
    );
    if (decoded is! Map || decoded['settings'] is! Map) {
      throw BackendException('Invalid agent settings response.');
    }
    return AgentSettings.fromJson(
      (decoded['settings'] as Map).cast<String, Object?>(),
    );
  }

  /// Persist one supported selection group for the scope.
  Future<AgentSettings> updateAgentSetting(
    String agentKey,
    String group,
    String optionId,
  ) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/agent-settings',
      body: <String, Object?>{'agent': agentKey, group: optionId},
    );
    if (decoded is! Map || decoded['settings'] is! Map) {
      throw BackendException('Invalid agent settings response.');
    }
    return AgentSettings.fromJson(
      (decoded['settings'] as Map).cast<String, Object?>(),
    );
  }

  /// Installed CLI version string for the agent (for the model page label).
  Future<String> fetchAgentVersion(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/agent-version?agent=${Uri.encodeQueryComponent(agentKey)}',
    );
    if (decoded is Map && decoded['version'] is String) {
      return (decoded['version'] as String).trim();
    }
    return '';
  }

  /// Update the agent's CLI binary so newly shipped models become selectable.
  /// Slow (network install), so it uses a long timeout.
  Future<AgentUpdateResult> updateAgentCli(String agentKey) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/agent-update',
      body: <String, Object?>{'agent': agentKey},
      timeout: const Duration(seconds: 200),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid agent update response.');
    }
    return AgentUpdateResult.fromJson(decoded.cast<String, Object?>());
  }

  /// Clears the backend-side session for one agent so the next message starts
  /// a new machine-side conversation after local history is cleared.
  Future<void> clearSession(String agentKey, String sessionId) async {
    await _requestJson(
      'POST',
      '/api/session/clear',
      body: <String, Object?>{'agent': agentKey, 'sessionId': sessionId},
    );
  }

  Future<WorkdirInfo> workdir() async {
    final Object? decoded = await _requestJson('GET', '/api/workdir');
    if (decoded is! Map) {
      throw BackendException('Invalid work directory response.');
    }
    return WorkdirInfo.fromJson(decoded.cast<String, Object?>());
  }

  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/workdir',
      body: <String, Object?>{'path': path, 'create': create},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid work directory update response.');
    }
    final WorkdirInfo info = WorkdirInfo.fromJson(
      decoded.cast<String, Object?>(),
    );
    // The backend only validates the path; this device owns its current workdir,
    // so persist the canonical path locally and send it on later requests.
    if (info.dir.isNotEmpty) {
      await _transport.writeWorkdir(info.dir);
    }
    return info;
  }

  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) async {
    final String queryPath = Uri.encodeQueryComponent(path);
    final Object? decoded = await _requestJson(
      'GET',
      '/api/workdir/browse?path=$queryPath&showHidden=$showHidden',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid work directory browser response.');
    }
    return FsListing.fromJson(decoded.cast<String, Object?>());
  }

  /// Opens a streaming download. [FsDownloadStream.bytes] is the live response
  /// stream; the caller writes it straight to disk (native) or a blob (web) so a
  /// large file is never buffered whole in memory. Throws before any bytes (e.g.
  /// FS_DOWNLOAD_TOO_LARGE) when the server rejects the request up front.
  Future<FsDownloadStream> openFileDownload(String path) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(
      credential,
      '/api/fs/download?path=${Uri.encodeQueryComponent(path)}',
    );
    final http.Request request = http.Request('GET', uri);
    request.headers.addAll(
      await _headers(credential, accept: 'application/octet-stream'),
    );
    final http.StreamedResponse response =
        await _httpClient.send(request).timeout(const Duration(minutes: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String text = await response.stream.bytesToString();
      throw _exceptionFor(response.statusCode, text);
    }
    final int? total =
        (response.contentLength != null && response.contentLength! > 0)
            ? response.contentLength
            : null;
    return FsDownloadStream(
      fileName: _downloadFileName(response.headers, path),
      total: total,
      bytes: response.stream.timeout(const Duration(minutes: 15)),
    );
  }

  Future<FsEntry> uploadFile({
    required String path,
    required String name,
    required Uint8List bytes,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(
      credential,
      '/api/fs/upload?path=${Uri.encodeQueryComponent(path)}'
      '&name=${Uri.encodeQueryComponent(name)}',
    );
    final http.Response response = await _httpClient
        .post(
          uri,
          headers: await _headers(
            credential,
            contentType: 'application/octet-stream',
          ),
          body: bytes,
        )
        .timeout(const Duration(minutes: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, response.body);
    }
    return _uploadedEntryFromBody(response.body);
  }

  Future<FsEntry> uploadFileStream({
    required String path,
    required String name,
    required Stream<List<int>> bytes,
    required int length,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(
      credential,
      '/api/fs/upload?path=${Uri.encodeQueryComponent(path)}'
      '&name=${Uri.encodeQueryComponent(name)}',
    );
    final http.StreamedRequest request = http.StreamedRequest('POST', uri);
    request.headers.addAll(
      await _headers(
        credential,
        contentType: 'application/octet-stream',
      ),
    );
    request.contentLength = length;
    final Future<http.StreamedResponse> responseFuture =
        _httpClient.send(request).timeout(const Duration(minutes: 10));
    await request.sink.addStream(bytes);
    await request.sink.close();
    final http.StreamedResponse response = await responseFuture;
    final String body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, body);
    }
    return _uploadedEntryFromBody(body);
  }

  FsEntry _uploadedEntryFromBody(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map || decoded['entry'] is! Map) {
      throw BackendException('Invalid file upload response.');
    }
    return FsEntry.fromJson((decoded['entry'] as Map).cast<String, Object?>());
  }

  Stream<BackendEvent> streamEvents() async* {
    final MachineCredential credential = await _requireCredential();
    final http.Request request = http.Request(
      'GET',
      _uri(credential, '/api/events'),
    );
    request.headers.addAll(
      await _headers(credential, accept: 'text/event-stream'),
    );

    final http.StreamedResponse response = await _httpClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String text = await response.stream.bytesToString();
      throw _exceptionFor(response.statusCode, text);
    }

    yield* decodeSse(response.stream.timeout(const Duration(seconds: 90)));
  }

  ChatReply _chatReplyFromStreamDone(
    Map<String, Object?> json,
    String requestId,
    String agentKey,
  ) {
    final Map<String, Object?> agent =
        (json['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final Map<String, Object?> message =
        (json['message'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return ChatReply(
      requestId: json['requestId'] as String? ?? requestId,
      agentKey: agent['key'] as String? ?? agentKey,
      agentLabel: agent['label'] as String? ?? agentKey,
      content: message['content'] as String? ?? '',
      segments: _segmentsFromMessage(message),
    );
  }

  Future<Object?> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) =>
      _transport.requestJson(method, path, body: body, timeout: timeout);

  Future<Object?> _requestJsonWithCredential(
    MachineCredential credential,
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) =>
      _transport.requestJsonWithCredential(
        credential,
        method,
        path,
        body: body,
        timeout: timeout,
      );

  Future<MachineCredential> _requireCredential() =>
      _transport.requireCredential();

  Uri _uri(MachineCredential credential, String path) =>
      _transport.uri(credential, path);

  Future<Map<String, String>> _headers(
    MachineCredential credential, {
    String accept = 'application/json',
    String contentType = 'application/json',
  }) =>
      _transport.headers(
        credential,
        accept: accept,
        contentType: contentType,
      );

  String _downloadFileName(Map<String, String> headers, String path) {
    final String disposition = headers['content-disposition'] ?? '';
    final RegExpMatch? encoded = RegExp(
      r"filename\*=UTF-8''([^;]+)",
    ).firstMatch(disposition);
    if (encoded != null) {
      return Uri.decodeComponent(encoded.group(1)!);
    }
    final RegExpMatch? plain = RegExp(
      r'filename="?([^";]+)"?',
    ).firstMatch(disposition);
    if (plain != null) return plain.group(1)!;
    final List<String> parts =
        path.split('/').where((String p) => p.isNotEmpty).toList();
    return parts.isEmpty ? 'workdir.zip' : parts.last;
  }

  BackendException _exceptionFor(int status, String body) =>
      _transport.exceptionFor(status, body);

  BackendException _networkExceptionFor(Object err, Uri uri) =>
      _transport.networkExceptionFor(err, uri);
}
