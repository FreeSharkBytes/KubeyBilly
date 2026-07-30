# Incident 20260724T100000Z-a1b2c3d4 (recovered)

Workload: Deployment web in namespace demo. Everything below is
generated from the structured incident record; no model wrote any of it.

## Timeline

| Time (UTC) | Event | Detail |
| --- | --- | --- |
| 2026-07-24 10:00:00 | opened |  |
| 2026-07-24 10:00:02 | evidence sealed |  |
| 2026-07-24 10:00:03 | permitted | reason: the rollback tier permits automatic action at confidence 0.9; rule_id: tier-auto; verdict: permit_auto |
| 2026-07-24 10:00:04 | executed | result: {dry_run: false} |
| 2026-07-24 10:01:34 | verified recovered | polls: 3; reason: recovered_sustained; unmet: none |

## Soundings

The evidence bundle was captured at 2026-07-24T10:00:01Z, before anything was touched. Paths are relative to the incident directory.

| Artifact | Bytes |
| --- | --- |
| pods/demo/web-9f8d7c6b5-aaaaa/logs-previous.txt | 48213 |
| pods/demo/web-9f8d7c6b5-aaaaa/logs-current.txt | 1024 |
| pods/demo/web-9f8d7c6b5-aaaaa/status.json | 2048 |
| owners/demo/web.json | 4096 |
| owners/demo/web-revisions.json | 3072 |
| events/demo.json | 900 |
| metrics/baseline.json | 512 |

No gaps were recorded; the capture is complete.

## Signature

- Name: imagepull_post_rollout
- Confidence: 0.9
- Rationale: Containers are waiting on ImagePullBackOff and the newest ReplicaSet revision changed the image; the bad image arrived with the rollout.
- Evidence:
  - pods/demo/web-9f8d7c6b5-aaaaa/status.json
  - owners/demo/web-revisions.json

## Decision

- Verdict: permit_auto
- Deciding rule: tier-auto
- Rule chain: kill-switch, mode, scope, deny-kinds, budgets, tier-auto
- Reason: the rollback tier permits automatic action at confidence 0.9

## Action

- Action: rollback_deployment
- Params: name: web; namespace: demo; to_revision: 1
- Undo: `kubectl rollout undo deployment/web --to-revision=2 -n demo`

## Verification

Outcome: recovered. The verification window opened at
2026-07-24 10:00:04 and closed at 2026-07-24 10:01:34 (UTC), after 3 polls.

Why: recovery held for two consecutive polls.

## Open questions

None. Nothing here is waiting on a human decision.
