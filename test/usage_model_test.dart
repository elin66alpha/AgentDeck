import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';

void main() {
  group('UsageQuota.fromJson', () {
    test('parses percentage and reset time', () {
      final UsageQuota q = UsageQuota.fromJson(<String, Object?>{
        'key': 'five_hour',
        'label': '5 hour quota',
        'remainingPercent': 42.5,
        'resetsAt': '2026-06-19T08:00:00.000Z',
      });
      expect(q.key, 'five_hour');
      expect(q.remainingPercent, 42.5);
      expect(q.resetsAt, '2026-06-19T08:00:00.000Z');
      expect(q.expired, isFalse);
    });

    test('defaults expired to false when absent', () {
      expect(
        UsageQuota.fromJson(<String, Object?>{'key': 'five_hour'}).expired,
        isFalse,
      );
    });

    test('reads the expired flag from the backend', () {
      final UsageQuota q = UsageQuota.fromJson(<String, Object?>{
        'key': 'five_hour',
        'remainingPercent': 80,
        'resetsAt': '2026-06-19T08:00:00.000Z',
        'expired': true,
      });
      expect(q.expired, isTrue);
      // The stale percentage is still carried, but the UI suppresses it.
      expect(q.remainingPercent, 80);
    });
  });

  group('UsageAgent.fromJson', () {
    test('parses nested quotas and propagates the expired flag', () {
      final UsageAgent agent = UsageAgent.fromJson(<String, Object?>{
        'key': 'codex',
        'label': 'Codex',
        'available': true,
        'stale': true,
        'asOf': '2026-06-19T07:00:00.000Z',
        'quotas': <Object?>[
          <String, Object?>{'key': 'five_hour', 'expired': true},
          <String, Object?>{'key': 'seven_day', 'expired': false},
        ],
      });
      expect(agent.key, 'codex');
      expect(agent.available, isTrue);
      expect(agent.stale, isTrue);
      expect(agent.quotas, hasLength(2));
      expect(agent.quotas[0].expired, isTrue);
      expect(agent.quotas[1].expired, isFalse);
    });

    test('handles an unavailable agent with no quotas', () {
      final UsageAgent agent = UsageAgent.fromJson(<String, Object?>{
        'key': 'codex',
        'label': 'Codex',
        'available': false,
        'unavailableReason': 'codex is not logged in',
      });
      expect(agent.available, isFalse);
      expect(agent.unavailableReason, 'codex is not logged in');
      expect(agent.quotas, isEmpty);
    });
  });
}
