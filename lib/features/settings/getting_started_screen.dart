import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';

class GettingStartedScreen extends StatelessWidget {
  const GettingStartedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final List<_GettingStartedStep> steps = strings.isZh ? _zhSteps : _enSteps;
    return Scaffold(
      appBar: AppBar(title: Text(strings.gettingStarted)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      strings.gettingStarted,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      strings.isZh
                          ? 'Relay 可以把你自己机器上的 CLI 智能体，变成手机、网页或桌面都能打开的聊天入口。'
                          : 'Relay turns CLI agents on your own machine into a chat workspace you can open from mobile, web, or desktop.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                    ),
                    const SizedBox(height: 20),
                    for (int index = 0; index < steps.length; index += 1)
                      _GettingStartedStepTile(
                        index: index + 1,
                        step: steps[index],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GettingStartedStepTile extends StatelessWidget {
  const _GettingStartedStepTile({
    required this.index,
    required this.step,
  });

  final int index;
  final _GettingStartedStep step;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: Text(
                '$index',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    step.title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    step.body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GettingStartedStep {
  const _GettingStartedStep({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;
}

const List<_GettingStartedStep> _zhSteps = <_GettingStartedStep>[
  _GettingStartedStep(
    title: '连接后端机器',
    body:
        '先在自己的电脑或服务器上部署 Relay 后端，并在主机上安装、登录或配置 CLI 智能体。应用不会替你登录 CLI。\n在“管理凭证”导入后端生成的二维码图片或 JSON，输入生成时设置的密码；移动端也可用摄像头扫码。多台机器可分别导入并切换，首页会显示当前连接的机器。',
  ),
  _GettingStartedStep(
    title: '先确认工作区，再开始任务',
    body:
        '首页显示当前工作区和最多三个有聊天记录的最近工作区。新设备默认使用后端的 ~/Relay（部署可覆盖默认值）。\n从左侧栏打开“文件系统”，进入项目目录，点击“设为工作路径”。这是后端机器上的目录；后续聊天会在这个目录执行。每台设备独立选择工作目录，切换目录也会切换对应的聊天记录和蜂群列表。',
  ),
  _GettingStartedStep(
    title: '在机器详情检查 CLI 状态',
    body:
        '点击首页或左侧栏里的机器，打开“机器详情”：这里集中显示 SSH 入口、CLI 智能体状态、设备令牌和后端状态。\n在主机上完成 Claude Code、Codex 的认证，或 OpenCode、Hermes 的 provider 配置后，重新检查状态。Codex 的显式检查会向 app-server 验证当前认证；网络或验证错误不一定表示需要重新登录，Codex 也不显示登录到期倒计时。',
  ),
  _GettingStartedStep(
    title: '选择智能体和会话',
    body:
        '左侧栏先列出 CLI 智能体，再列出蜂群。选择可用的智能体，并通过会话选择器新建或切换任务；每个工作目录下，每个智能体最多有八个命名会话，Main 不能删除。\n聊天标题第一行是工作区，第二行是“智能体 - 会话”。发送前核对这两行，避免在错误项目中操作。同一个工作区、智能体和会话在不同设备上共享历史。',
  ),
  _GettingStartedStep(
    title: '设置模型、思考强度和权限',
    body:
        '在聊天输入区域选择该智能体支持的模型、思考强度和权限等级，再发送任务。模型和选项以主机上 CLI 的能力为准。\n这些设置按“工作区 + 智能体”保存，会影响该上下文的所有命名会话及设备。Claude Code 和 Codex 另有默认关闭的 Fast 模式，可用性取决于模型及账号。Relay 会按所选权限等级处理 CLI 的审批请求，请按任务需要选择。',
  ),
  _GettingStartedStep(
    title: '描述任务，查看和找回结果',
    body:
        '可以先发送“解释这个项目的结构”，再补充具体修改要求。回复会流式显示，执行中可以取消；切换页面后可回到原会话继续查看。\n通过历史搜索查找当前工作区的消息，并跳转到对应会话；需要保存结果时可导出当前对话为 Markdown。新任务可建立独立会话，后续追问则留在原会话。',
  ),
  _GettingStartedStep(
    title: '用蜂群分工协作',
    body:
        '创建蜂群时选择工作树，配置成员昵称、角色提示、模型和权限；创建后工作树不可更改。蜂群列表属于当前工作区，但成员在蜂群选定的工作树里执行。\n发送“@成员名 请检查这段代码”来指定回答者；同时提及多名成员可让他们并行处理。成员回复里的 @提及也可继续召唤队友，默认最多追加三轮，具体上限由部署配置决定。可将成员配置导出为 JSON 模板复用。',
  ),
  _GettingStartedStep(
    title: '浏览、上传和下载文件',
    body:
        '“文件系统”可浏览后端允许访问的目录，上传待处理材料、下载结果，也可下载文件夹。文件列表向右滑动可返回上一级。\n“设为工作路径”用于切换当前项目；上传前先确认所在目录。后端会限制敏感路径，部署也可以限定允许访问的范围。',
  ),
  _GettingStartedStep(
    title: '从机器详情进入 SSH 终端',
    body:
        '点击“机器详情 → 进入 SSH”，即可打开后端机器的交互式终端。每个设备凭证对应一个可恢复终端，离开页面再回来会尝试接回原终端。\nAndroid 和 iOS 提供 Ctrl、Shift、Esc、Tab 和方向键；Ctrl / Shift 点一次后只作用于下一个输入，例如先点 Ctrl 再输入 c 发送 Ctrl+C。终端使用后端系统用户的完整权限，不受文件浏览器的路径限制。',
  ),
  _GettingStartedStep(
    title: '查看用量与管理设备',
    body:
        '“用量查询”分别加载 Claude Code 和 Codex 的卡片；一张卡片仍在等待时，另一张可以先显示结果。此页面用于查看额度，与机器详情中的认证状态不同。\n在机器详情检查设备令牌与最近使用信息。不再使用的设备可先撤销令牌再删除记录；撤销当前设备会断开自己的访问及终端。需要重读本教程时，可从首页“教程”或设置进入。',
  ),
];

const List<_GettingStartedStep> _enSteps = <_GettingStartedStep>[
  _GettingStartedStep(
    title: 'Connect a backend machine',
    body:
        'Deploy Relay on your own computer or server and install and authenticate or configure the CLI agents there. Relay does not log you into a CLI.\nIn Manage credentials, import the generated QR image or JSON and enter its passphrase. Mobile also supports camera scanning. Import multiple machines separately and switch between them; Home shows the current connection.',
  ),
  _GettingStartedStep(
    title: 'Choose the workspace before starting',
    body:
        'Home shows the current workspace and up to three recent workspaces with chat history. A new device defaults to ~/Relay on the backend unless the deployment overrides it.\nOpen File system from the drawer, navigate to your project, and select Set as work path. This is a directory on the backend machine where tasks will run. Each device chooses its own directory; switching it also changes the associated history and Swarm list.',
  ),
  _GettingStartedStep(
    title: 'Check CLI status in Machine details',
    body:
        'Tap the machine on Home or in the drawer to open Machine details, which brings together Enter SSH, CLI agent status, device tokens, and backend status.\nAfter authenticating Claude Code or Codex, or configuring an OpenCode or Hermes provider on the host, recheck the status. An explicit Codex recheck verifies current authentication with its app-server. A network or verification error does not necessarily mean login is required, and Codex has no login-expiry countdown.',
  ),
  _GettingStartedStep(
    title: 'Choose an agent and conversation',
    body:
        'The drawer lists CLI agents above Swarm. Choose an available agent, then create or switch tasks through the session picker. Each agent in each workdir supports up to eight named conversations; Main cannot be deleted.\nThe chat header shows the workspace, with “Agent - Session” below it. Check both before sending a task. Devices using the same workspace, agent, and session share its history.',
  ),
  _GettingStartedStep(
    title: 'Set the model, effort, and permissions',
    body:
        'Use the chat composer controls to select the supported model, reasoning effort, and permission tier before sending a task. Available options depend on the CLI on the host.\nSettings are saved per workspace and agent, so all named sessions and devices in that context share them. Claude Code and Codex also offer Fast mode, off by default and subject to model and account availability. Relay handles CLI approval requests according to the chosen permission tier; select it to fit the task.',
  ),
  _GettingStartedStep(
    title: 'Describe tasks and find results',
    body:
        'Start with a request such as “explain this project structure”, then add specific changes. Replies stream as work progresses, and you can cancel a running turn. Return to the same conversation after switching pages to follow its progress.\nSearch history in the current workspace and jump to a matching conversation. Export the current conversation as Markdown to keep the result. Use separate sessions for new tasks and the existing session for follow-up questions.',
  ),
  _GettingStartedStep(
    title: 'Divide work with a Swarm',
    body:
        'When creating a Swarm, select its work tree and configure member nicknames, role prompts, models, and permissions. Its work tree cannot be changed later. The Swarm is listed under the current workspace, while members execute in its selected work tree.\nMention @member-name to choose who answers. Mention several members to run them in parallel. Members can summon teammates through mentions in their replies, with up to three additional waves by default, depending on deployment settings. Export the member configuration as a reusable JSON template.',
  ),
  _GettingStartedStep(
    title: 'Browse, upload, and download files',
    body:
        'File system browses directories permitted by the backend, uploads input files, and downloads results or folders. Swipe right on the file list to go up one directory.\nSet as work path changes the active project. Check the displayed directory before uploading. The backend restricts sensitive paths, and a deployment may further limit accessible directories.',
  ),
  _GettingStartedStep(
    title: 'Open the SSH terminal from Machine details',
    body:
        'Choose Machine details → Enter SSH for an interactive terminal on the backend. Each device credential owns a resumable terminal; leaving and returning attempts to reconnect to it.\nAndroid and iOS provide Ctrl, Shift, Esc, Tab, and arrow keys. Ctrl and Shift apply only to the next input: tap Ctrl then type c to send Ctrl+C. The terminal runs with the full permissions of the backend OS user and is not constrained by file-browser path restrictions.',
  ),
  _GettingStartedStep(
    title: 'Check usage and manage devices',
    body:
        'Usage query loads Claude Code and Codex cards independently, so one can show results while the other is still loading. Usage reporting is separate from authentication status in Machine details.\nReview device tokens and last-use details in Machine details. Revoke an unused device before deleting its record; revoking the current device disconnects your own access and terminal. Reopen this guide from the Tutorial section on Home or from Settings.',
  ),
];
