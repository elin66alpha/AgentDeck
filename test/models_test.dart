import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/models/agent_options.dart';
import 'package:relay/core/models/agent_session.dart';
import 'package:relay/core/models/chat_message.dart';
import 'package:relay/core/models/group.dart';

void main() {
  group('ChatGroup.fromJson', () {
    test('parses a full swarm payload', () {
      final ChatGroup g = ChatGroup.fromJson(<String, Object?>{
        'id': 'g1',
        'name': 'Reviewers',
        'members': <Object?>['claude', 'codex'],
        'workdir': '/work/tree',
        'memberConfigs': <String, Object?>{
          'claude': <String, Object?>{
            'model': 'opus',
            'nickname': 'Lead',
            'prompt': 'be terse',
          },
        },
      });
      expect(g.id, 'g1');
      expect(g.name, 'Reviewers');
      expect(g.members, <String>['claude', 'codex']);
      expect(g.workdir, '/work/tree');
      expect(g.memberConfigs['claude'],
          <String, String>{'model': 'opus', 'nickname': 'Lead', 'prompt': 'be terse'},);
    });

    test('applies defaults and drops empty members', () {
      final ChatGroup g = ChatGroup.fromJson(<String, Object?>{
        'members': <Object?>['claude', '', null, 'codex'],
      });
      expect(g.id, '');
      expect(g.name, 'Swarm');
      expect(g.workdir, '');
      expect(g.members, <String>['claude', 'codex']);
      expect(g.memberConfigs, isEmpty);
    });

    test('_configsFrom skips non-map values and empty ids', () {
      final ChatGroup g = ChatGroup.fromJson(<String, Object?>{
        'members': <Object?>['claude'],
        'memberConfigs': <String, Object?>{
          'claude': <String, Object?>{'model': 'opus', 'effort': '', 'x': 1},
          'codex': 'not-a-map',
          'empty': <String, Object?>{'model': ''},
        },
      });
      expect(g.memberConfigs['claude'], <String, String>{'model': 'opus'});
      expect(g.memberConfigs.containsKey('codex'), isFalse);
      expect(g.memberConfigs.containsKey('empty'), isFalse);
    });

    test('memberLabels resolves known agent keys', () {
      final ChatGroup g = ChatGroup.fromJson(<String, Object?>{
        'members': <Object?>['claude', 'codex', 'opencode'],
      });
      expect(g.memberLabels, <String>['Claude Code', 'Codex', 'OpenCode']);
    });
  });

  group('groupAuthorLabel', () {
    test('maps human / empty / null to You', () {
      expect(groupAuthorLabel('human'), 'You');
      expect(groupAuthorLabel(''), 'You');
      expect(groupAuthorLabel(null), 'You');
    });

    test('maps an agent key to its label', () {
      expect(groupAuthorLabel('codex'), 'Codex');
    });

    test('falls back to the default agent label for an unknown key', () {
      expect(groupAuthorLabel('mystery'), 'Claude Code');
    });
  });

  group('ChatMessage', () {
    test('fromJson parses role, content and timestamp', () {
      final ChatMessage m = ChatMessage.fromJson(<String, Object?>{
        'id': 'm1',
        'role': 'user',
        'content': 'hello',
        'createdAt': '2026-01-02T03:04:05.000Z',
      });
      expect(m.id, 'm1');
      expect(m.role, ChatRole.user);
      expect(m.isUser, isTrue);
      expect(m.content, 'hello');
      expect(m.createdAt.toUtc(),
          DateTime.utc(2026, 1, 2, 3, 4, 5),);
    });

    test('fromJson defaults an unknown role to assistant', () {
      final ChatMessage m =
          ChatMessage.fromJson(<String, Object?>{'role': 'wizard'});
      expect(m.role, ChatRole.assistant);
      expect(m.isUser, isFalse);
    });

    test('segments parse from metadata and are empty when absent', () {
      final ChatMessage withSegments =
          ChatMessage.assistant('full', metadata: <String, Object?>{
        'segments': <Object?>[
          <String, Object?>{'text': 'step 1', 'ts': '2026-01-02T03:04:05.000Z'},
          <String, Object?>{'text': 'final'},
        ],
      },);
      final List<MessageSegment> segs = withSegments.segments;
      expect(segs.map((MessageSegment s) => s.text), <String>['step 1', 'final']);
      expect(segs[0].createdAt, isNotNull);
      expect(segs[1].createdAt, isNull);

      expect(ChatMessage.assistant('x').segments, isEmpty);
    });

    test('toJson round-trips through fromJson', () {
      final ChatMessage original = ChatMessage.fromJson(<String, Object?>{
        'id': 'm9',
        'role': 'assistant',
        'content': 'reply',
        'createdAt': '2026-05-06T07:08:09.000Z',
        'metadata': <String, Object?>{'author': 'claude'},
      });
      final ChatMessage restored = ChatMessage.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.role, original.role);
      expect(restored.content, original.content);
      expect(restored.createdAt, original.createdAt);
      expect(restored.metadata, original.metadata);
    });
  });

  group('AgentOptionsCatalog', () {
    final AgentOptionsCatalog catalog =
        AgentOptionsCatalog.fromJson(<String, Object?>{
      'agent': 'claude',
      'supports': <String, Object?>{'model': true, 'effort': false},
      'model': <Object?>[
        <String, Object?>{'id': ' opus ', 'label': ' Opus ', 'description': ' big '},
        <String, Object?>{'id': '', 'label': 'dropped'},
        'not-a-map',
      ],
      'permission': <Object?>[
        <String, Object?>{'id': 'safe', 'label': 'Safe'},
      ],
      'defaults': <String, Object?>{'model': 'opus', 'bad': 1},
    });

    test('parses options, trimming and dropping id-less entries', () {
      expect(catalog.agent, 'claude');
      expect(catalog.model, hasLength(1));
      final AgentOption opt = catalog.model.single;
      expect(opt.id, 'opus');
      expect(opt.label, 'Opus');
      expect(opt.description, 'big');
    });

    test('exposes supports and defaults', () {
      expect(catalog.supportsGroup('model'), isTrue);
      expect(catalog.supportsGroup('effort'), isFalse);
      expect(catalog.supportsGroup('permission'), isFalse);
      expect(catalog.defaults, <String, String>{'model': 'opus'});
    });

    test('optionsFor returns the right group and empty for unknown', () {
      expect(catalog.optionsFor('permission').single.id, 'safe');
      expect(catalog.optionsFor('effort'), isEmpty);
      expect(catalog.optionsFor('nonsense'), isEmpty);
    });

    test('uses model-specific effort choices and defaults when present', () {
      final AgentOptionsCatalog modelAware =
          AgentOptionsCatalog.fromJson(<String, Object?>{
        'agent': 'codex',
        'supports': <String, Object?>{'model': true, 'effort': true},
        'model': <Object?>[
          <String, Object?>{'id': 'gpt-new', 'label': 'GPT New'},
          <String, Object?>{'id': 'gpt-lite', 'label': 'GPT Lite'},
          <String, Object?>{'id': 'gpt-none', 'label': 'GPT None'},
        ],
        'effort': <Object?>[
          <String, Object?>{'id': 'medium', 'label': 'Medium'},
        ],
        'effortByModel': <String, Object?>{
          'gpt-new': <Object?>[
            <String, Object?>{'id': 'high', 'label': 'High'},
            <String, Object?>{'id': 'xhigh', 'label': 'Extra high'},
          ],
          'gpt-none': <Object?>[],
          'bad-entry': 'not-a-list',
        },
        'defaults': <String, Object?>{
          'model': 'gpt-new',
          'effort': 'medium',
        },
        'defaultEffortByModel': <String, Object?>{
          'gpt-new': 'xhigh',
          'gpt-none': 'medium',
          'bad-entry': 42,
        },
      });

      expect(
        modelAware
            .optionsFor('effort', modelId: 'gpt-new')
            .map((AgentOption option) => option.id),
        <String>['high', 'xhigh'],
      );
      expect(
        modelAware.optionsFor('effort', modelId: 'gpt-lite').single.id,
        'medium',
      );
      expect(
        modelAware.optionsFor('effort', modelId: 'gpt-none'),
        isEmpty,
      );
      expect(
        modelAware.defaultFor('effort', modelId: 'gpt-new'),
        'xhigh',
      );
      expect(
        modelAware.defaultFor('effort', modelId: 'gpt-lite'),
        'medium',
      );
      expect(modelAware.effortByModel.containsKey('bad-entry'), isFalse);
      expect(modelAware.defaultEffortByModel.containsKey('bad-entry'), isFalse);
    });

    test('resolveSelection replaces stale values with a valid fallback', () {
      final AgentOptionsCatalog modelAware =
          AgentOptionsCatalog.fromJson(<String, Object?>{
        'supports': <String, Object?>{'model': true, 'effort': true},
        'model': <Object?>[
          <String, Object?>{'id': 'gpt-new', 'label': 'GPT New'},
        ],
        'effortByModel': <String, Object?>{
          'gpt-new': <Object?>[
            <String, Object?>{'id': 'high', 'label': 'High'},
            <String, Object?>{'id': 'xhigh', 'label': 'Extra high'},
          ],
        },
        'defaults': <String, Object?>{'model': 'missing'},
        'defaultEffortByModel': <String, Object?>{'gpt-new': 'xhigh'},
      });

      expect(modelAware.resolveSelection('model', 'stale'), 'gpt-new');
      expect(
        modelAware.resolveSelection(
          'effort',
          'stale',
          modelId: 'gpt-new',
        ),
        'xhigh',
      );
      expect(
        modelAware.resolveSelection(
          'effort',
          'high',
          modelId: 'gpt-new',
        ),
        'high',
      );
      expect(modelAware.resolveSelection('permission', 'stale'), isNull);
    });

    test('AgentOption description becomes null when blank', () {
      final AgentOption opt = AgentOption.fromJson(<String, Object?>{
        'id': 'x',
        'label': 'X',
        'description': '   ',
      });
      expect(opt.description, isNull);
    });
  });

  group('AgentSettings', () {
    test('fromJson keeps only string values', () {
      final AgentSettings s = AgentSettings.fromJson(<String, Object?>{
        'model': 'opus',
        'effort': 42,
      });
      expect(s['model'], 'opus');
      expect(s['effort'], isNull);
    });

    test('copyWith returns a new map without mutating the original', () {
      const AgentSettings base = AgentSettings(<String, String>{'model': 'opus'});
      final AgentSettings next = base.copyWith('effort', 'high');
      expect(next['model'], 'opus');
      expect(next['effort'], 'high');
      expect(base['effort'], isNull);
    });
  });

  group('AgentSession', () {
    test('fromJson fills defaults for missing fields', () {
      final AgentSession s = AgentSession.fromJson(<String, Object?>{});
      expect(s.id, AgentSession.defaultId);
      expect(s.name, 'Main');
      expect(s.isDefault, isTrue);
    });

    test('toJson preserves id and name', () {
      final AgentSession s = AgentSession.fromJson(<String, Object?>{
        'id': 's2',
        'name': 'Feature',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
      });
      expect(s.isDefault, isFalse);
      final Map<String, Object?> json = s.toJson();
      expect(json['id'], 's2');
      expect(json['name'], 'Feature');
    });
  });

  group('AgentUpdateResult.fromJson', () {
    test('parses flags and output', () {
      final AgentUpdateResult r = AgentUpdateResult.fromJson(<String, Object?>{
        'ok': true,
        'before': ' 1.0 ',
        'after': ' 1.1 ',
        'changed': true,
        'timedOut': false,
        'output': ' updated ',
      });
      expect(r.ok, isTrue);
      expect(r.before, '1.0');
      expect(r.after, '1.1');
      expect(r.changed, isTrue);
      expect(r.timedOut, isFalse);
      expect(r.output, 'updated');
    });
  });
}
