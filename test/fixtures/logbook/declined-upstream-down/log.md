# Incident 20260724T110000Z-b2c3d4e5 (escalated)

Workload: Deployment web in namespace demo. Everything below is
generated from the structured incident record; no model wrote any of it.

## Timeline

| Time (UTC) | Event | Detail |
| --- | --- | --- |
| 2026-07-24 11:00:00 | opened |  |
| 2026-07-24 11:00:02 | evidence sealed |  |
| 2026-07-24 11:00:03 | no action | rationale: Pod demo/web-6c5d4b3a2-fffff depends on Service "backend" via env DATABASE_HOST, and the baseline recorded it with zero ready endpoints. Acting on the victim of an upstream outage makes things worse; the upstream must recover first. |

## Soundings

The evidence bundle was captured at 2026-07-24T11:00:01Z, before anything was touched. Paths are relative to the incident directory.

| Artifact | Bytes |
| --- | --- |
| pods/demo/web-6c5d4b3a2-fffff/spec.json | 2200 |
| pods/demo/web-6c5d4b3a2-fffff/status.json | 1800 |
| events/demo.json | 1400 |
| metrics/baseline.json | 640 |

No gaps were recorded; the capture is complete.

## Signature

- Name: upstream_down
- Confidence: 0.9
- Rationale: Pod demo/web-6c5d4b3a2-fffff depends on Service "backend" via env DATABASE_HOST, and the baseline recorded it with zero ready endpoints. Acting on the victim of an upstream outage makes things worse; the upstream must recover first.
- Evidence:
  - metrics/baseline.json

## Decision

- Verdict: permit_auto
- Deciding rule: tier-auto
- Rule chain: kill-switch, mode, scope, deny-kinds, budgets, tier-auto
- Reason: no_action is always permitted

## Action

- Action: no_action
- Params: reason: Pod demo/web-6c5d4b3a2-fffff depends on Service "backend" via env DATABASE_HOST, and the baseline recorded it with zero ready endpoints. Acting on the victim of an upstream outage makes things worse; the upstream must recover first.
- Undo: `nothing to undo`

## Verification

No verification ran; the incident closed before any action took effect.

## Open questions

- The incident escalated on "no action" (rationale: Pod demo/web-6c5d4b3a2-fffff depends on Service "backend" via env DATABASE_HOST, and the baseline recorded it with zero ready endpoints. Acting on the victim of an upstream outage makes things worse; the upstream must recover first.). A human needs to take it from here; the evidence above is the handoff.
- An upstream dependency was down: Pod demo/web-6c5d4b3a2-fffff depends on Service "backend" via env DATABASE_HOST, and the baseline recorded it with zero ready endpoints. Acting on the victim of an upstream outage makes things worse; the upstream must recover first. Confirm the upstream has recovered before acting on this workload again.
