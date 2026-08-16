import 'package:flutter/widgets.dart';

import '../settings/app_settings_controller.dart';

class AppScope extends InheritedNotifier<AppSettingsController> {
  const AppScope({
    required AppSettingsController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppSettingsController settingsOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  }

  static AppStrings stringsOf(BuildContext context) {
    return AppStrings(settingsOf(context).language);
  }
}

extension AppStringsContext on BuildContext {
  AppStrings get l10n => AppScope.stringsOf(this);
  AppSettingsController get appSettings => AppScope.settingsOf(this);
}

class AppStrings {
  const AppStrings(this.appLanguage);

  final AppLanguage appLanguage;
  bool get isZh => appLanguage == AppLanguage.zh;

  String get appName => 'Relay';
  String get home => isZh ? '首页' : 'Home';
  String get backHome => isZh ? '回到首页' : 'Back to Home';
  String get gettingStarted => isZh ? '开始使用' : 'Getting started';
  String get notConnected => isZh ? '未连接机器' : 'No machine connected';
  String get manageCredentials => isZh ? '管理凭证' : 'Manage credentials';
  String get manageCredentialsHomeHint => isZh
      ? '查看 CLI 智能体状态与凭据有效期'
      : 'Check CLI agent status and credential expiry';
  String get cliAgents => isZh ? 'CLI 智能体' : 'CLI agents';
  String get groupChat => isZh ? '蜂群' : 'Swarm';
  String get groupChatSubtitle => isZh ? '多智能体蜂群协作' : 'Multi-agent swarm';
  String get newGroup => isZh ? '新建蜂群' : 'New swarm';
  String get groupName => isZh ? '蜂群名称' : 'Swarm name';
  String get groupMembers => isZh ? '成员' : 'Members';
  String get manageMembers => isZh ? '管理成员' : 'Manage members';
  String get deleteGroup => isZh ? '删除蜂群' : 'Delete swarm';
  String get deleteGroupConfirm =>
      isZh ? '删除该蜂群及其聊天记录？' : 'Delete this swarm and its transcript?';
  String get clearTranscript => isZh ? '清空记录' : 'Clear transcript';
  String get noGroups => isZh ? '还没有蜂群' : 'No swarms yet';
  String get groupEmptyHint =>
      isZh ? '用 @ 召唤成员，例如 @claude' : 'Mention a member with @, e.g. @claude';
  String get groupComposerHint =>
      isZh ? '输入消息，用 @ 召唤成员' : 'Message — use @ to summon members';
  String get selectMembers =>
      isZh ? '请至少选择一个成员。' : 'Select at least one member.';
  String get swarmWorkTree => isZh ? '工作目录 (work tree)' : 'Work tree';
  String get swarmWorkTreeDefault =>
      isZh ? '默认（当前工作区）' : 'Default (current workspace)';
  String get swarmChooseWorkTree => isZh ? '选择工作目录' : 'Choose work tree';
  String get swarmConfigureMembers => isZh ? '配置成员' : 'Configure members';
  String get swarmConfigureMembersHint => isZh
      ? '为每个成员选择模型、思考深度与权限'
      : 'Pick a model, reasoning effort, and permission per member';
  String get memberNickname => isZh ? '昵称（仅本蜂群）' : 'Nickname (this swarm)';
  String get memberNicknameHint =>
      isZh ? '留空则用默认名称' : 'Leave blank to use the default name';
  String get memberPrompt => isZh ? '工作 / 提示词' : 'Task / prompt';
  String get memberPromptHint => isZh
      ? '这个成员在本蜂群里的工作内容，仅在此蜂群生效'
      : "This member's job in this swarm — applies only here";
  String editMemberTitle(String label) =>
      isZh ? '配置 $label' : 'Configure $label';
  String get saveSwarmTemplate => isZh ? '保存为模板' : 'Save as template';
  String get importSwarmTemplate => isZh ? '导入模板' : 'Import template';
  String get swarmTemplateSaved => isZh ? '模板已下载' : 'Template downloaded';
  String swarmTemplateImported(String name) =>
      isZh ? '已从模板创建「$name」' : 'Created "$name" from template';
  String get swarmTemplateInvalid => isZh ? '模板文件无效' : 'Invalid template file';
  String swarmTemplateFailed(Object err) =>
      isZh ? '模板操作失败：$err' : 'Template operation failed: $err';
  String get browse => isZh ? '浏览' : 'Browse';
  String get usage => isZh ? '额度' : 'Usage';
  String get usageQuery => isZh ? '额度查询' : 'Quota usage';
  String get usageTitle => isZh ? '额度剩余' : 'Quota remaining';
  String get loadingUsage => isZh ? '正在查询额度...' : 'Loading quota...';
  String get fiveHourQuota => isZh ? '5 小时' : '5 hours';
  String get weeklyQuota => isZh ? '本周' : 'This week';
  String get remaining => isZh ? '剩余' : 'remaining';
  String get refreshAt => isZh ? '刷新' : 'Refresh';
  String usageAsOf(String value) => isZh ? '截至 $value' : 'As of $value';
  String get usageStale => isZh ? '上次成功结果' : 'Stale';
  String get quotaWindowReset =>
      isZh ? '配额窗口已重置，等待最新数据' : 'Window reset — awaiting fresh data';
  String get quotaScheduler => isZh ? '定时消息' : 'Scheduled messages';
  String get prompt => isZh ? '消息内容' : 'Message';
  String scheduleUpdated(String agent) =>
      isZh ? '已更新 $agent 的预设消息。' : 'Updated scheduled message for $agent.';
  String scheduleFailed(Object err) =>
      isZh ? '预设消息失败：$err' : 'Scheduled message failed: $err';
  String get messageRequired => isZh ? '请输入消息内容。' : 'Enter a message.';
  String get clearSchedule => isZh ? '清除已排程' : 'Clear scheduled';
  String scheduleCleared(String agent) =>
      isZh ? '已清除 $agent 的预设消息。' : 'Cleared scheduled message for $agent.';

  String get unavailable => isZh ? '暂未开放' : 'Not available yet';
  String get unknown => isZh ? '未知' : 'Unknown';
  String get status => isZh ? '状态' : 'Status';
  String get backendOnline => isZh ? '后端在线' : 'Backend online';
  String workDirectoryLine(String path) =>
      isZh ? '工作目录：$path' : 'Work directory: $path';
  String systemUptimeLine(String value) =>
      isZh ? '系统运行：$value' : 'System uptime: $value';
  String processUptimeLine(String value) =>
      isZh ? '进程运行：$value' : 'Process uptime: $value';
  String publicBaseUrlLine(String value) =>
      isZh ? '公网地址：$value' : 'Public URL: $value';
  String taskTimeoutLine(int minutes) =>
      isZh ? '任务超时：$minutes 分钟' : 'Task timeout: $minutes minutes';
  String quotaWatchLine(bool enabled) => isZh
      ? '额度监听：${enabled ? '开启' : '关闭'}'
      : 'Quota watch: ${enabled ? 'enabled' : 'disabled'}';
  String diagnosticsGeneratedLine(String value) =>
      isZh ? '诊断时间：$value' : 'Diagnostics time: $value';
  String diagnosticsRuntimeLine(String platform, String arch, String node) =>
      isZh ? '运行环境：$platform/$arch，$node' : 'Runtime: $platform/$arch, $node';
  String diagnosticsListenLine(String host, int port) =>
      isZh ? '监听地址：$host:$port' : 'Listening on: $host:$port';
  String diagnosticsWorkdirLine({
    required bool exists,
    required bool writable,
  }) =>
      isZh
          ? '工作目录状态：${exists ? '存在' : '不存在'}，${writable ? '可写' : '不可写'}'
          : 'Workdir state: ${exists ? 'exists' : 'missing'}, ${writable ? 'writable' : 'not writable'}';
  String diagnosticsDefaultWorkdirLine(String value) =>
      isZh ? '默认工作目录：$value' : 'Default workdir: $value';
  String diagnosticsTransferLimitLine(String upload, String download) => isZh
      ? '传输上限：上传 $upload，下载 $download'
      : 'Transfer limits: upload $upload, download $download';
  String diagnosticsTokenLine({
    required bool configured,
    required int active,
    required int total,
  }) =>
      isZh
          ? 'Token：${configured ? '已配置' : '未配置'}，活跃 $active / 总计 $total'
          : 'Tokens: ${configured ? 'configured' : 'not configured'}, active $active / total $total';
  String diagnosticsRequestLine({
    required int active,
    required int running,
    required int queued,
    required int sse,
  }) =>
      isZh
          ? '运行中：请求 $active，scope $running，队列 $queued，SSE $sse'
          : 'Runtime: requests $active, scopes $running, queued $queued, SSE $sse';
  String diagnosticsWebBuildLine(bool exists) => isZh
      ? 'Web 构建：${exists ? '存在' : '缺失'}'
      : 'Web build: ${exists ? 'present' : 'missing'}';
  String get diagnosticsAgentsHeader => isZh ? 'CLI 检查：' : 'CLI checks:';
  String diagnosticsAgentLine(
    String label, {
    required bool available,
    required bool? loggedIn,
    required String path,
  }) {
    final String login = loggedIn == null
        ? (isZh ? '登录未知' : 'login unknown')
        : (loggedIn
            ? (isZh ? '已登录' : 'logged in')
            : (isZh ? '未登录' : 'not logged in'));
    final String cli =
        available ? (isZh ? '可执行' : 'available') : (isZh ? '未找到' : 'not found');
    final String suffix = path.isEmpty ? '' : ' ($path)';
    return '- $label: $cli, $login$suffix';
  }

  String get diagnosticsStorageHeader => isZh ? '存储文件：' : 'Storage files:';
  String diagnosticsStorageLine(
    String name, {
    required bool exists,
    required bool writable,
    required String size,
  }) =>
      isZh
          ? '- $name：${exists ? '存在' : '不存在'}，${writable ? '可写' : '不可写'}，$size'
          : '- $name: ${exists ? 'exists' : 'missing'}, ${writable ? 'writable' : 'not writable'}, $size';
  String get deviceTokens => isZh ? '设备 Token' : 'Device tokens';
  String get noDeviceTokens => isZh ? '没有设备 Token。' : 'No device tokens.';
  String get currentDeviceToken => isZh ? '当前设备' : 'Current device';
  String get revokedDeviceToken => isZh ? '已吊销' : 'Revoked';
  String tokenCreatedAt(String value) => isZh ? '创建：$value' : 'Created: $value';
  String tokenRevokedAt(String value) => isZh ? '吊销：$value' : 'Revoked: $value';
  String tokenUsedBy(String value) => isZh ? '使用端：$value' : 'Used by: $value';
  String tokenLastUsedAt(String value) =>
      isZh ? '最近使用：$value' : 'Last used: $value';
  String get revokeToken => isZh ? '吊销' : 'Revoke';
  String get deleteToken => isZh ? '删除' : 'Delete';
  String get revokeCurrentTokenTitle =>
      isZh ? '吊销当前设备 Token？' : 'Revoke this device token?';
  String get revokeCurrentTokenBody => isZh
      ? '这会让本设备的下一次 API 请求返回 401。继续后需要重新导入有效凭证。'
      : 'The next API request from this device will return 401. You will need to import a valid credential again.';
  String tokenRevoked(String label) => isZh ? '已吊销 $label。' : 'Revoked $label.';
  String tokenRevokeFailed(Object err) =>
      isZh ? '吊销 Token 失败：$err' : 'Token revoke failed: $err';
  String tokenDeleted(String label) => isZh ? '已删除 $label。' : 'Deleted $label.';
  String tokenDeleteFailed(Object err) =>
      isZh ? '删除 Token 失败：$err' : 'Token delete failed: $err';
  String get fileSystem => isZh ? '文件系统' : 'File system';
  String get currentFolder => isZh ? '当前文件夹' : 'Current folder';
  String get parentFolder => isZh ? '上一级' : 'Parent folder';
  String get showHiddenFiles => isZh ? '显示隐藏文件' : 'Show hidden files';
  String get hideHiddenFiles => isZh ? '不显示隐藏文件' : 'Hide hidden files';
  String get emptyFolder => isZh ? '这个文件夹是空的。' : 'This folder is empty.';
  String get loadingFiles => isZh ? '正在读取文件...' : 'Loading files...';
  String get uploadFile => isZh ? '上传文件' : 'Upload file';
  String get download => isZh ? '下载' : 'Download';
  String get dragDropUpload => isZh
      ? 'Web 端可以把文件拖到此页上传。'
      : 'On web, drag files onto this page to upload.';
  String uploadingFile(String name) => isZh ? '正在上传：$name' : 'Uploading: $name';
  String uploadComplete(int count) =>
      isZh ? '已上传 $count 个文件。' : '$count file(s) uploaded.';
  String uploadFailed(Object err) => isZh ? '上传失败：$err' : 'Upload failed: $err';
  String downloadFailed(Object err) =>
      isZh ? '下载失败：$err' : 'Download failed: $err';
  String downloadProgress(String name, int percent) =>
      isZh ? '正在下载 $name（$percent%）' : 'Downloading $name ($percent%)';
  String downloadIndeterminate(String name) =>
      isZh ? '正在下载 $name…' : 'Downloading $name…';
  String get downloadComplete => isZh ? '下载完成' : 'Download complete';
  String get downloadFailedTitle => isZh ? '下载失败' : 'Download failed';
  String savedTo(String location) =>
      isZh ? '已保存到：$location' : 'Saved to: $location';
  String get savedToBrowserDownloads =>
      isZh ? '已下载到浏览器的下载文件夹。' : 'Saved to your browser’s downloads folder.';
  String downloadTooLarge(String limit) => isZh
      ? '文件超过下载上限（$limit），无法下载。'
      : 'This download exceeds the size limit ($limit) and was blocked.';
  String uploadTooLarge(String name, String limit) => isZh
      ? '$name 超过上传上限（$limit），未上传。'
      : '$name exceeds the upload limit ($limit) and was not uploaded.';
  String get setAsWorkPath => isZh ? '设为工作路径' : 'Set as work path';
  String currentWorkPath(String path) =>
      isZh ? '当前工作路径：$path' : 'Work path: $path';
  String get workPathTag => isZh ? '工作路径' : 'Work path';
  String get transferLimitHint => isZh
      ? '单次下载（含打包文件夹）上限 300 MB，单个上传文件上限 100 MB。'
      : 'Downloads (incl. zipped folders) cap at 300 MB; each uploaded file at 100 MB.';
  String get fileTypeDirectory => isZh ? '文件夹' : 'Folder';
  String get fileTypeFile => isZh ? '文件' : 'File';
  String get fileTypeOther => isZh ? '其他' : 'Other';
  String get workdirUpdated => isZh ? '工作路径已更新。' : 'Work directory updated.';
  String get workdirBusy => isZh
      ? '当前有 agent 正在运行，请结束后再修改工作路径。'
      : 'An agent task is running. Change the work directory after it finishes.';
  String localChatSessionResetFailed(Object err) => isZh
      ? '已清空本地对话，但重置机器会话失败：$err'
      : 'Local chat was cleared, but resetting the machine session failed: $err';
  String get agentBusyRetryLater => isZh
      ? '该 agent 正在处理上一条消息，请稍后重试。'
      : 'This agent is still handling the previous message. Try again later.';
  String get agentQueued => isZh
      ? '排队中…（前一条消息还在处理）'
      : 'Queued — waiting for the current turn to finish…';
  String agentErrorLine(String error) => isZh ? '出错：$error' : 'Error: $error';
  String agentNotLoggedIn(String agent) => isZh
      ? '$agent 在后端主机上未登录，请在主机上登录后重试。'
      : '$agent is not logged in on the backend host. Log in there, then try again.';
  String agentNotLoggedInBanner(String agent) => isZh
      ? '$agent 未登录：请在后端主机上登录该 CLI。'
      : '$agent is not logged in. Log in to this CLI on the backend host.';
  String agentCliNotInstalled(String agent) => isZh
      ? '$agent 未安装在后端主机上。'
      : '$agent is not installed on the backend host.';
  String agentNeedsLogin(String agent) =>
      isZh ? '$agent 需要先在后端主机上登录。' : '$agent needs login on the backend host.';
  String agentNeedsApiKey(String agent) => isZh
      ? '$agent 需要先配置供应商和 API key。'
      : '$agent needs a provider and API key first.';
  String agentUnavailable(String agent) =>
      isZh ? '$agent 当前不可用。' : '$agent is not available.';
  String agentInstalledStatus(bool installed) => isZh
      ? '安装：${installed ? '已安装' : '未安装'}'
      : 'Installed: ${installed ? 'yes' : 'no'}';
  String agentAuthStatus(bool authed, String authKind) {
    final String label = switch (authKind) {
      'apiKey' => isZh ? 'API key' : 'API key',
      'apiKeyOptional' => isZh ? '可用' : 'Usable',
      _ => isZh ? '登录' : 'Login',
    };
    return isZh
        ? '$label：${authed ? '已就绪' : '未就绪'}'
        : '$label: ${authed ? 'ready' : 'not ready'}';
  }

  String get recheck => isZh ? '重新检查' : 'Recheck';
  String get optionalApiKey => isZh ? 'API key 可选' : 'API key optional';
  String get keyManagedOnHost => isZh ? '在主机上配置' : 'Configured on host';
  String get agentReady => isZh ? '已就绪' : 'Ready';
  String get copy => isZh ? '复制' : 'Copy';
  String get copied => isZh ? '已复制。' : 'Copied.';
  String credentialExpiresInDays(int days) => isZh
      ? '还有 $days 天需要重新登录'
      : 'Log in again in $days ${days == 1 ? 'day' : 'days'}';
  String get credentialExpiresToday =>
      isZh ? '今天之内需要重新登录' : 'Log in again within a day';
  String credentialExpiredDays(int days) => isZh
      ? '已过期 $days 天，请立即在后端主机重新登录'
      : 'Expired $days ${days == 1 ? 'day' : 'days'} ago. '
          'Log in again on the backend host.';
  String get credentialExpiredToday => isZh
      ? '凭据已过期，请立即在后端主机重新登录'
      : 'Credential expired. Log in again on the backend host.';
  String agentStatusRefreshFailed(Object err) =>
      isZh ? '刷新智能体状态失败：$err' : 'Agent status refresh failed: $err';
  String get importCredential => isZh ? '导入凭证' : 'Import credential';
  String get scanQr => isZh ? '扫描二维码' : 'Scan QR code';
  String get pasteCredential => isZh ? '粘贴凭证' : 'Paste credential';
  String get uploadQrImage => isZh ? '上传二维码图片' : 'Upload QR image';
  String get credentialPayload => isZh ? '凭证内容' : 'Credential payload';
  String get credentialPayloadHint => isZh
      ? '粘贴终端生成的二维码内容或加密凭证 JSON'
      : 'Paste the QR payload or encrypted credential JSON generated on the machine';
  String get menu => isZh ? '菜单' : 'Menu';
  String get clearChat => isZh ? '清空当前对话' : 'Clear chat';
  String get searchChats => isZh ? '搜索对话' : 'Search chats';
  String get searchHint =>
      isZh ? '搜索当前工作目录的历史消息' : 'Search history in this workdir';
  String get currentAgentOnly => isZh ? '只搜索当前智能体' : 'Current agent only';
  String get noSearchResults => isZh ? '没有匹配结果。' : 'No matches.';
  String searchFailed(Object err) => isZh ? '搜索失败：$err' : 'Search failed: $err';
  String get exportMarkdown => isZh ? '导出 Markdown' : 'Export Markdown';
  String exportFailed(Object err) => isZh ? '导出失败：$err' : 'Export failed: $err';
  String get close => isZh ? '关闭' : 'Close';
  String get ok => isZh ? '确认' : 'OK';
  String get cancel => isZh ? '取消' : 'Cancel';
  String get clear => isZh ? '清空' : 'Clear';
  String get create => isZh ? '创建' : 'Create';
  String get delete => isZh ? '删除' : 'Delete';
  String get newSession => isZh ? '新建会话' : 'New session';
  String get sessionName => isZh ? '会话名称' : 'Session name';
  String defaultSessionName(int index) => isZh ? '会话 $index' : 'Session $index';
  String get sessionRunning => isZh ? '正在运行' : 'Running';
  String backgroundSessionFinished(String agent, String session) =>
      isZh ? '$agent · $session 已完成。' : '$agent · $session finished.';
  String get deleteSession => isZh ? '删除会话' : 'Delete session';
  String deleteSessionTitle(String name) =>
      isZh ? '删除 $name？' : 'Delete $name?';
  String get deleteSessionBody => isZh
      ? '这个会话的聊天记录和机器侧上下文都会被删除，工作目录里的文件不会受影响。'
      : 'This deletes the chat history and machine-side context for this session. Files in the workdir are not changed.';
  String sessionActionFailed(Object err) =>
      isZh ? '会话操作失败：$err' : 'Session action failed: $err';
  String get stop => isZh ? '停止' : 'Stop';
  String get send => isZh ? '发送' : 'Send';
  String get moreChatActions => isZh ? '更多操作' : 'More actions';

  // Per-agent Model / Effort / Permission controls (composer "+" drawer).
  String get agentModel => isZh ? '模型' : 'Model';
  String get agentEffort => isZh ? '思考' : 'Effort';
  String get agentPermission => isZh ? '权限' : 'Permission';
  String get agentFastMode => isZh ? '快速模式' : 'Fast mode';
  String get agentFastModeHint =>
      isZh ? '以更高用量或费用换取更快响应' : 'Faster responses with increased usage or cost';
  String get agentModelTitle => isZh ? '选择模型' : 'Select model';
  String get agentEffortTitle => isZh ? '思考能力' : 'Effort level';
  String get agentPermissionTitle => isZh ? '权限模式' : 'Permission mode';
  String get agentEffortMinimal => isZh ? '极低' : 'Minimal';
  String get agentEffortLow => isZh ? '低' : 'Low';
  String get agentEffortMedium => isZh ? '中' : 'Medium';
  String get agentEffortHigh => isZh ? '高' : 'High';
  String get agentEffortExtraHigh => isZh ? '极高' : 'Extra high';
  String get agentEffortMax => isZh ? '最高' : 'Max';
  String get agentEffortUltra => isZh ? '极限' : 'Ultra';
  String get agentControlsUnsupported =>
      isZh ? '该智能体不支持此项' : 'Not supported by this agent';
  String get agentControlsLoadFailed =>
      isZh ? '加载失败,点按重试' : 'Failed to load — tap to retry';
  String agentSettingSaveFailed(Object err) =>
      isZh ? '保存失败:$err' : 'Save failed: $err';
  String agentCliVersion(String version) =>
      isZh ? '当前版本 $version' : 'Version $version';
  String get agentUpdateCli => isZh ? '更新 CLI' : 'Update CLI';
  String get agentUpdateMissingModel => isZh ? '模型不可用?' : 'Model unavailable?';
  String agentUpdateConfirmTitle(String agent) =>
      isZh ? '更新 $agent?' : 'Update $agent?';
  String get agentUpdateConfirmBody => isZh
      ? '将在后端主机上运行 CLI 自更新,可能耗时一两分钟。完成后会刷新可用模型和思考深度。'
      : 'Runs the CLI self-update on the backend host. This can take a minute or two; available models and effort levels refresh when it finishes.';
  String get agentUpdating => isZh ? '正在更新…' : 'Updating…';
  String agentUpdateDone(String before, String after) =>
      isZh ? '更新完成:$before → $after' : 'Updated: $before → $after';
  String get agentUpdateNoChange => isZh ? '已是最新版本' : 'Already up to date';
  String agentUpdateFailed(Object err) =>
      isZh ? '更新失败:$err' : 'Update failed: $err';
  String get agentUpdateTimedOut =>
      isZh ? 'CLI 更新超时。' : 'CLI update timed out.';
  String get agentUpdateCommandFailed =>
      isZh ? 'CLI 更新命令执行失败。' : 'CLI update command failed.';

  String get retry => isZh ? '重试' : 'Retry';
  String get cancelled => isZh ? '已取消' : 'Cancelled';
  String get inputHint => isZh ? '输入消息' : 'Message';
  String get inputHintFollowUp => isZh ? '输入跟进消息…' : 'Send a follow-up…';
  String get queuedFollowUp => isZh ? '排队中' : 'Queued';
  String agentProgressUpdates(int count) => isZh
      ? '思索过程 · $count 条'
      : 'Thinking · $count ${count == 1 ? 'update' : 'updates'}';
  String get agentThinking => isZh ? '思考过程' : 'Thinking';
  String agentSteps(int count) =>
      isZh ? '执行步骤 · $count 条' : '$count ${count == 1 ? 'step' : 'steps'}';
  String startChat(String agent) =>
      isZh ? '与 $agent 开始对话' : 'Start chatting with $agent';
  String get chooseConversationTarget => isZh
      ? '请在左侧抽屉里选择蜂群或 CLI 智能体来开始工作'
      : 'Choose a swarm or CLI agent from the left drawer to start';
  String get homeSubtitle => isZh
      ? '从这里查看机器状态，并快速回到最近的蜂群或智能体会话。'
      : 'Check the machine status and jump back into recent swarm or agent sessions.';
  String get recentSwarms => isZh ? '最近使用的蜂群' : 'Recent swarms';
  String get recentAgentSessions =>
      isZh ? '最近使用的智能体会话' : 'Recent agent sessions';
  String get noRecentSwarms => isZh
      ? '还没有蜂群。可以从左侧栏创建一个。'
      : 'No swarms yet. Create one from the left drawer.';
  String get noRecentAgentSessions => isZh
      ? '还没有智能体会话。可以从左侧栏选择一个 CLI 智能体开始。'
      : 'No agent sessions yet. Choose a CLI agent from the left drawer to start.';
  String agentSessionLabel(String agent, String session) =>
      isZh ? '$agent · $session' : '$agent · $session';
  String get gettingStartedHomeHint => isZh
      ? '第一次使用或忘记流程时，从这里快速查看步骤。'
      : 'Use this when you are new or want a quick reminder.';
  String get credentialTitle => isZh ? '机器凭证' : 'Machine credentials';
  String get currentMachine => isZh ? '当前机器' : 'Current machine';
  String get enterSsh => isZh ? '进入SSH' : 'Enter SSH';
  String get sshTerminal => isZh ? 'SSH 终端' : 'SSH terminal';
  String get backToCredentials =>
      isZh ? '返回管理凭证' : 'Back to machine credentials';
  String get sshTerminalExited =>
      isZh ? '终端会话已退出。' : 'The terminal session has exited.';
  String get sshTerminalReplaced =>
      isZh ? '这个终端已在另一个窗口中打开。' : 'This terminal was opened in another window.';
  String get sshTerminalConnectionFailed =>
      isZh ? '无法连接 SSH 终端。' : 'Could not connect to the SSH terminal.';
  String get testMachine => isZh ? '测试当前机器' : 'Test current machine';
  String get importOrChooseMachine =>
      isZh ? '请导入或选择一台机器' : 'Import or choose a machine';
  String get loadingStatus => isZh ? '正在获取状态...' : 'Loading status...';
  String statusLoadFailed(Object err) =>
      isZh ? '连接失败：$err' : 'Connection failed: $err';
  String get noStatus => isZh ? '未获取到状态' : 'No status received';
  String get refresh => isZh ? '刷新' : 'Refresh';
  String get importMachineCredential =>
      isZh ? '导入机器凭证' : 'Import machine credential';
  String get emptyCredentialText => isZh
      ? '导入机器上脚本生成的凭证二维码或二维码内容，然后输入凭证密码。'
      : 'Import the credential QR code or QR payload generated by the script on the machine, then enter the credential password.';
  String get deployBackendGuide =>
      isZh ? '如何部署后端？' : 'How to deploy the backend?';
  String get credentialPassword => isZh ? '凭证密码' : 'Credential password';
  String get password => isZh ? '密码' : 'Password';
  String get passwordHint =>
      isZh ? '生成凭证时设置的密码' : 'Password set when generating the credential';
  String get decrypt => isZh ? '解密' : 'Decrypt';
  String get settings => isZh ? '设置' : 'Settings';
  String get notifications => isZh ? '通知' : 'Notifications';
  String get quotaAlerts => isZh ? '额度刷新提醒' : 'Quota reset alerts';
  String get taskAlerts => isZh ? '任务完成提醒' : 'Task completion alerts';
  String get tutorial => isZh ? '教程' : 'Tutorial';
  String get about => isZh ? '关于' : 'About';
  String get aboutApp => isZh ? '关于应用' : 'About this app';
  String get version => isZh ? '版本' : 'Version';
  String get fontSize => isZh ? '字体大小' : 'Font size';
  String get fontSizeDescription =>
      isZh ? '调整整个应用的文字大小' : 'Adjust text size across the app';
  String fontScalePercent(int value) => '$value%';
  String get resetFontSize => isZh ? '重置字体大小' : 'Reset font size';
  String get license => isZh ? '许可' : 'License';
  String get licenseText => isZh ? '私有本地工具。' : 'Private local tool.';
  String get copyright => isZh ? '© 2026 Relay' : '© 2026 Relay';
  String get aboutDescription => isZh
      ? '用于连接本机 Claude Code、Codex、OpenCode 和 Hermes CLI 智能体的私有控制台。'
      : 'Private control surface for local Claude Code, Codex, OpenCode, and Hermes CLI agents.';
  String get language => isZh ? '语言' : 'Language';
  String get appearance => isZh ? '外观' : 'Appearance';
  String get online => isZh ? '在线' : 'Online';
  String get offline => isZh ? '未在线' : 'Not online';
  String get compress => isZh ? '压缩对话' : 'Compress';
  String get compressComplete => isZh ? '压缩完成' : 'Compression complete';
  String get conversationCompacted => isZh ? '对话已压缩' : 'Conversation compacted';
  String compressFailed(Object err) =>
      isZh ? '压缩失败：$err' : 'Compression failed: $err';
  String get english => 'English';
  String get chinese => '中文';
  String get systemTheme => isZh ? '跟随系统' : 'System';
  String get lightTheme => isZh ? '白天' : 'Light';
  String get darkTheme => isZh ? '黑夜' : 'Dark';
  String get fileUnreadable =>
      isZh ? '无法读取凭证。' : 'Unable to read the credential.';
  String imported(String name) => isZh ? '已导入：$name' : 'Imported: $name';
  String get importFailedTitle => isZh ? '导入失败' : 'Import failed';
  String get credentialDecryptFailed => isZh
      ? '凭证解密失败。请确认二维码和密码是否正确。'
      : 'Credential decryption failed. Check the QR code and password.';
  String credentialBackendNotOk(String host) => isZh
      ? '已解密凭证，但 $host 没有返回正常状态。'
      : 'The credential decrypted, but $host did not return a healthy status.';
  String credentialTokenRejected(String host) => isZh
      ? '已连接到 $host，但凭证 token 被拒绝。这个二维码可能已经过期，或对应 token 已被吊销。请在后端重新生成二维码，并导入最新二维码。'
      : 'Connected to $host, but the credential token was rejected. This QR may be stale, or its token was revoked. Regenerate the QR on the backend and import the latest QR.';
  String credentialHostLookupFailed(String host) => isZh
      ? '无法解析 $host。请确认二维码里的地址仍然有效；如果使用 Cloudflare quick tunnel，请在后端重新生成二维码。'
      : 'Cannot resolve $host. Make sure the QR URL is still valid. If you use Cloudflare quick tunnel, regenerate the QR on the backend.';
  String credentialConnectionRefused(String host) => isZh
      ? '能找到 $host，但后端端口拒绝连接。请确认 Relay 后端正在运行，并监听二维码里的端口。'
      : '$host resolved, but the backend port refused the connection. Make sure the Relay backend is running and listening on the QR port.';
  String credentialNetworkUnreachable(String host) => isZh
      ? '无法连接到 $host。请确认网络可用、后端在线，或 Cloudflare quick tunnel 仍在运行。'
      : 'Cannot reach $host. Make sure the network is available, the backend is online, or the Cloudflare quick tunnel is still running.';
  String credentialConnectionTimedOut(String host) => isZh
      ? '连接 $host 超时。请确认后端在线，并且二维码地址仍然有效。'
      : 'Timed out connecting to $host. Make sure the backend is online and the QR URL is still valid.';
  String credentialConnectionFailed(String host, Object err) =>
      isZh ? '无法连接到 $host：$err' : 'Could not connect to $host: $err';
  String get plaintextCredentialTitle =>
      isZh ? '使用明文 HTTP 连接？' : 'Use plaintext HTTP?';
  String plaintextCredentialBody(String host) => isZh
      ? '$host 使用 http://，请求、聊天内容、文件和 bearer token 会以明文传输。仅在可信局域网或自托管环境中继续。'
      : '$host uses http://. Requests, chat content, files, and the bearer token will travel without encryption. Continue only on a trusted local or self-hosted network.';
  String get continueImport => isZh ? '继续' : 'Continue';
  String get testingCredentialConnection =>
      isZh ? '正在验证后端连接...' : 'Testing backend connection...';
  String get credentialDecryptTimedOut => isZh
      ? '凭证解密耗时过长。请确认二维码图片有效，或在后端重新生成最新二维码后再试。'
      : 'Credential decryption took too long. Check the QR image, or regenerate the latest QR on the backend and try again.';
  String get credentialQrDecodeTimedOut => isZh
      ? '二维码图片解析耗时过长。请上传后端保存的二维码 PNG，或重新生成最新二维码后再试。'
      : 'QR image parsing took too long. Upload the backend-saved QR PNG, or regenerate the latest QR and try again.';
  String get connectionOk => isZh ? '连接正常。' : 'Connection OK.';
  String get backendNotOk => isZh ? '后端没有返回 ok。' : 'Backend did not return ok.';
  String connectionFailed(Object err) =>
      isZh ? '连接失败：$err' : 'Connection failed: $err';
  // Human-readable message for a low-level network failure, keyed by the
  // BackendException network code (see ApiTransport.networkExceptionFor).
  String networkError(String? code) {
    switch (code) {
      case 'NETWORK_HOST_LOOKUP':
        return isZh
            ? '无法解析后端地址。请检查网络连接，或确认凭证里的地址仍然有效（quick tunnel 地址会变化，需重新生成二维码）。'
            : 'Cannot resolve the backend address. Check your network, or confirm the credential URL is still valid (quick-tunnel URLs change — regenerate the QR).';
      case 'NETWORK_CONNECTION_REFUSED':
        return isZh
            ? '后端拒绝连接。请确认 Relay 后端正在运行并监听对应端口。'
            : 'The backend refused the connection. Make sure the Relay backend is running and listening on the expected port.';
      case 'NETWORK_UNREACHABLE':
        return isZh
            ? '无法连接到后端。请检查网络是否可用、后端是否在线。'
            : 'Cannot reach the backend. Check that your network is available and the backend is online.';
      case 'NETWORK_TIMEOUT':
        return isZh
            ? '连接后端超时。请确认后端在线后重试。'
            : 'Timed out reaching the backend. Make sure it is online and try again.';
      default:
        return isZh
            ? '网络错误：无法连接到后端。请检查网络后重试。'
            : 'Network error: cannot reach the backend. Check your connection and try again.';
    }
  }

  String deleteMachine(String name) => isZh ? '删除 $name？' : 'Delete $name?';
  String get deleteMachineBody => isZh
      ? '删除后需要重新扫描这台机器的凭证二维码。'
      : 'You will need to scan this machine credential QR again.';
  String get scanQrTitle => isZh ? '扫描凭证二维码' : 'Scan credential QR';
  String get scanQrHint =>
      isZh ? '对准终端或图片里的凭证二维码。' : 'Point the camera at the credential QR code.';
  String get invalidQr => isZh
      ? '二维码不是有效的 Relay 凭证。'
      : 'The QR code is not a valid Relay credential.';
  String get clearChatTitle => isZh ? '清空当前对话？' : 'Clear this chat?';
  String get clearChatBody => isZh
      ? '删除当前会话的历史消息，并在机器上为这个会话开启新的上下文（不影响工作目录里的文件）。'
      : 'Delete this session history and start a new machine-side context for it. Files in the workdir are not changed.';
}
