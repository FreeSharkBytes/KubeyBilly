# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Phoenix application skeleton without Ecto: evidence lives on disk, not in a
  database. Toolchain pinned (Elixir 1.20.2, Erlang/OTP 29.0.3), GitLab CI with
  separate lint, test, and build jobs.
- K8sClient behaviour with a real client over the k8s library and a Mox mock.
  In-cluster service account auth and kubeconfig fallback.
- Soundings: the evidence collector and bundle writer. Captures in value order
  (previous logs first, since they vanish on the next restart), seals a sha256
  manifest, records honest gap entries for anything it could not capture, and
  snapshots the verification baseline. Confirmed against a real OOMKill; that
  captured bundle ships as the first replay corpus fixture.
- Signature matchers for ImagePullBackOff, CrashLoopBackOff, OOMKilled, readiness
  failure after rollout, unschedulable pods, node NotReady, and missing ConfigMap or
  Secret. Rollout-correlated variants propose a rollback; the rest mostly decline,
  which is the point. An upstream dependency check can veto any action when the
  failure traces to a dead dependency.
- The formulary: a closed action set with live-cluster parameter validation, inverse
  construction with irreversibility classes, and client-side deployment rollback
  (there is no rollback verb in the Kubernetes API; the patch is built from the
  target ReplicaSet's template).
- Standing orders: a strict YAML policy parser and a pure evaluator with stable rule
  ids. Every decision carries its full rule chain, so permits are as auditable as
  refusals.
- Incident state machine, one gen_statem per incident, with an alert correlator that
  dedupes Alertmanager redeliveries by groupKey and guarantees one open incident per
  workload. Crashes and restarts close incidents as interrupted instead of resuming
  half-done mutations, and spent hourly budget survives a reboot.
- The executor, the only module that mutates the cluster: kill switch checked before
  every write, atomic budgets (reverts count), dry run as the default mode, and a
  refusal to act on any incident whose evidence bundle is not sealed complete.
- The verifier: recovered, unchanged, and worse judged against the soundings
  baseline, with two-poll stability, tolerance for inconclusive polls, and settling
  logic so a rollback's own pod churn does not read as things getting worse.
- LLM advisor boundary: stub by default, an OpenAI-compatible adapter for Scaleway
  Generative APIs behind it. Model confidence is capped at 0.7 in our code, and
  malformed model output degrades to a logged no-action.
- The logbook: a markdown incident report generated entirely from structured data,
  with the timeline, the evidence inventory, the decision chain, a copy-pastable
  undo command, and open questions for the human. An optional advisor narrative is
  clearly marked as generated.
- Alertmanager v4 webhook with bearer token auth, and a LiveView dashboard behind
  basic auth: incident list, incident detail with an evidence browser, and an
  approvals page that shows the rule chain before the approve button.
- Helm chart with least-privilege RBAC: four mutating verbs, no Secrets access on
  any verb, hardened pod spec, and ConfigMaps for standing orders and the kill
  switch.
- Container image with ERL_MAX_PORTS capped. Containerd hands pods an effectively
  unlimited file descriptor limit, and the BEAM sizes its port tables from it,
  allocating gigabytes at boot. Found the hard way on kind.

### Fixed

- Label selectors are now encoded as K8s.Selector structs; the k8s library rejects
  raw strings. Found by the first live-cluster run, not by the mocked tests.
- The imagepull matchers recognize ErrImageNeverPull, which is what kind reports
  under imagePullPolicy Never.
- Current logs of a container that never started are recorded as a structural
  absence rather than incompleteness, so image-pull incidents no longer escalate as
  evidence_incomplete before they can be matched.
- The baseline now records all namespace services, not only those selecting the
  target workload, so the upstream check can actually see a dead dependency. The
  collector also falls back to the workload selector when alerts carry no pod
  labels.
- The chart wires STANDING_ORDERS_PATH and KILLSWITCH_PATH into the pod; without
  them the deployed instance ran a default read-only policy and never saw the kill
  switch.
- The endpoint accepts same-host origins so the LiveView socket survives kubectl
  port-forward.
