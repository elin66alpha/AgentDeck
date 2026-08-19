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
    title: '先连接一台机器',
    body: '在你的电脑或服务器上启动 Relay 后端，然后在应用里导入这台机器生成的二维码凭证。连接成功后，首页会显示当前机器。',
  ),
  _GettingStartedStep(
    title: '选择一个 CLI 智能体',
    body:
        '打开左侧栏选择 agent。红绿状态灯表示安装和认证状态；所有 CLI 的登录或 provider 配置都要在后端主机上完成，然后可在“管理凭证”中重新检查状态。',
  ),
  _GettingStartedStep(
    title: '像发消息一样描述任务',
    body: '在输入框里直接说你想做什么，例如“帮我解释这个项目”或“修复这个报错”。智能体会在后端机器上执行。',
  ),
  _GettingStartedStep(
    title: '需要多人协作时使用蜂群',
    body: '蜂群可以把多个智能体放在同一个对话里。创建蜂群后，用 @某个成员 指定谁来回答。',
  ),
  _GettingStartedStep(
    title: '从首页快速回到最近工作',
    body: '首页会列出最近的蜂群和智能体会话。下次打开 Relay，可以从首页直接跳回上次的工作。',
  ),
  _GettingStartedStep(
    title: '文件系统用于查看和上传文件',
    body: '左侧栏的文件系统可以浏览后端允许的目录、设置工作目录、下载结果，或上传待处理文件。',
  ),
];

const List<_GettingStartedStep> _enSteps = <_GettingStartedStep>[
  _GettingStartedStep(
    title: 'Connect a machine first',
    body:
        'Start the Relay backend on your computer or server, then import the QR credential it creates. After connecting, the home page shows the current machine.',
  ),
  _GettingStartedStep(
    title: 'Choose a CLI agent',
    body:
        'Open the left drawer and choose an agent. Red/green lights show installation and authentication. Complete every CLI login or provider setup on the backend host, then recheck it from Manage credentials.',
  ),
  _GettingStartedStep(
    title: 'Describe the task like a message',
    body:
        'Type what you want in plain language, such as “explain this project” or “fix this error”. The agent runs on your backend machine.',
  ),
  _GettingStartedStep(
    title: 'Use swarms for multi-agent work',
    body:
        'A swarm puts multiple agents in one conversation. After creating one, mention a member with @ to choose who should respond.',
  ),
  _GettingStartedStep(
    title: 'Return to recent work from Home',
    body:
        'The home page lists recent swarms and agent sessions, so you can jump back into work quickly next time.',
  ),
  _GettingStartedStep(
    title: 'Use File system for files',
    body:
        'File system lets you browse backend directories allowed by the deployment, set the workdir, download results, or upload files.',
  ),
];
