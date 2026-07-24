# KubeyBilly

A first responder for Kubernetes. It freezes the evidence before it touches anything.

## The name

A handy-billy is a light portable rig kept aboard ship for emergencies. You grab it
when something is wrong right now, and it holds the situation together until a proper
repair can happen. That is the whole design of this project in one object.

## The problem it actually solves

Mitigation destroys evidence.

A pod gets OOMKilled at 3am. Something restarts it, availability recovers, and the
previous container's logs, the events, and the metric window are gone. The on-call
engineer arrives to a healthy cluster with no way to find out what happened, so the
outage comes back next Saturday.

That is the real reason auto-remediation is distrusted. Not that it takes wrong
actions, but that it burns the crime scene. Every tool in this space investigates and
stays read-only for exactly that reason. KubeyBilly takes the other path: act fast,
but capture everything first.

## What it does

An Alertmanager webhook fires. KubeyBilly then:

1. Correlates the alerts into one incident (thirty failing pods of one Deployment is
   one incident, one action).
2. Takes soundings: pod specs, statuses, current and previous logs, events, owner
   history, node state, and a verification baseline, all sealed to disk with a
   sha256 manifest before anything else happens.
3. Matches deterministic signatures against the frozen evidence. ImagePullBackOff
   after a rollout, CrashLoopBackOff, OOMKilled, readiness failures, and so on. An
   upstream check runs first: if the failure traces to a dead dependency, KubeyBilly
   declines to act and says why.
4. Evaluates the standing orders, a policy file with tiers, confidence floors, and
   budgets. Every decision records the full rule chain, permits included.
5. Executes at most one action from a closed formulary, with its inverse recorded
   before the call.
6. Watches a verification window and judges recovered, unchanged, or worse against
   the baseline it captured in step 2.
7. Reverts or freezes on worse, escalates on unchanged, and either way writes a human
   a markdown incident log with the timeline, the decision chain, a copy-pastable
   undo command, and the evidence attached.

It does not diagnose. It buys the on-call engineer time and preserves the state they
need to find the real cause.

## Vocabulary

The project uses naval damage control terms, consistently:

| Term | Meaning here |
|---|---|
| Soundings | Evidence collection, taken before any mutation |
| Standing orders | The policy file: what may be handled alone, what needs the captain |
| Formulary | The closed set of allowed actions |
| The log | The incident report handed to the human |
| Shoring | A mitigation that holds until a real fix |

## The safety envelope

This is the product, not a caveat on it.

- The formulary is closed: rollback, restart workload, restart pod, scale, cordon
  node, or decline. Nothing in the system ever emits kubectl, YAML, or shell.
- Declining is a first-class outcome. Most signatures propose no action at all,
  because restarting the victims of an upstream outage is noise, not help.
- Evidence comes before mutation. The executor refuses to act unless the incident's
  evidence bundle is sealed complete.
- Rules decide. An LLM only sees incidents no rule matched, can only pick from the
  formulary, and its confidence is capped below the auto-execution threshold, so a
  model proposal always needs a human yes. By default the model is a stub and no
  network call happens at all.
- Dry run is the default mode. Everything runs, nothing mutates, and the log records
  what would have happened.
- A kill switch (a ConfigMap key) is checked immediately before every write.
- Budgets cap actions per incident and per hour. Reverts count.
- A rollback that makes things worse is never auto-inverted, because the inverse
  would redeploy the image that was already failing. It freezes and calls the captain.
- RBAC grants exactly four mutating verbs (pods delete, deployments patch, scale
  patch, nodes patch) and no Secrets access on any verb. A policy bug cannot reach
  what the API server never granted.
- One incident is one supervised process. A crashed incident cannot take down alert
  ingest, and a restart closes interrupted incidents rather than resuming half-done
  mutations.

## Trying it

```
helm install kubeybilly charts/kubeybilly -n kubeybilly --create-namespace
```

The chart defaults to dry run mode and ships the RBAC described above. The full demo
environment (a deliberately breakable app, failure injection, tuned Prometheus and
Alertmanager, and one-command scenarios) lives in
[KubeyBilly-Demo](https://github.com/FreeSharkBytes/KubeyBilly-Demo): `make demo-up`,
then `make demo-1` through `demo-3`.

On a local kind cluster, scenario one (bad image tag, automatic rollback, verified
recovery, sealed evidence) runs in about 34 seconds from injection to written log.

## Complementary, not competing

k8sgpt, HolmesGPT, and their relatives investigate and explain. They are good at it,
and KubeyBilly does not try to replace them. It stabilizes, preserves the evidence
they will want, and hands off. Think of it as the first responder that secures the
scene before the detectives arrive.

## Out of scope, on purpose

No root cause analysis. No writes to persistent state (PVCs and StatefulSets are
deny-listed twice, in policy and in RBAC). No code changes or pull requests. No
multi-cluster. No autoscaling or cost decisions. A first responder that always acts
is not a first responder, it is a liability.

## Hosting

Canonical home: [GitLab](https://gitlab.com/freesharkbytes/kubeybilly/kubeybilly),
mirrored to [GitHub](https://github.com/FreeSharkBytes/KubeyBilly). Issues and merge
requests on GitLab.

Built for the Code Carnage hackathon under FreeSharkBytes.

## License

Apache 2.0. See [LICENSE](LICENSE).
