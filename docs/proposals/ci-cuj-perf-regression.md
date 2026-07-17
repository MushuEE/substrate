# Proposal: CUJ — Performance Regression Tracking

Status: draft for discussion
Part of: [ci-testinfra-architecture.md](./ci-testinfra-architecture.md)

## The journey

1. A maintainer can see the trend of Substrate's key latencies —
   request throughput under load, and the micro-VM lifecycle numbers
   (snapshot, restore, resume-from-pause) that are Substrate's
   differentiating surface — across recent commits to `main`.
2. A meaningful regression (error-rate spike, p99 blowout) turns a
   periodic job red and blocks the *release*, not anyone's PR.
3. A contributor whose change might affect performance can point at
   the harness and say "run this" instead of hand-rolling a
   benchmark.

Today: `benchmarking/` contains a real Locust harness
(`benchmarking/deploy_locust.sh`, workload manifests, optional
Prometheus/Grafana via `benchmarking/monitoring.yaml`), but it is
interactive — tests are started from the Locust web UI — and assumes
a GCP-style environment (`PROJECT_ID`, `BUCKET_NAME`). It has never
run in CI. There is no baseline: a 2x regression in actor resume
would ship silently.

## Studied practice

**Kubernetes sig-scalability** tiers perf tests by cost: medium fast
tests run as presubmits (catching ~60%+ of scalability regressions —
"a strong shield"); large expensive tests run as release-blocking
periodics, a status adopted after the 1.7 cycle showed non-blocking
scale tests get no traction from SIGs. Detection is primarily
dashboard-and-human because perf data is noisy; only *stable* SLO
checks (e.g. resource-usage bounds) fail runs automatically
([scalability regression case studies](https://github.com/kubernetes/community/blob/master/sig-scalability/governance/scalability-regressions-case-studies.md)).

**cilium** runs scheduled perf and scale workflows (`cilium
connectivity perf` on real clusters, scale tests) exporting results
keyed by tested SHA to a results bucket for trend dashboards —
explicitly not PR-gating. **etcd** runs one daily benchmark periodic
plus manual perf comparison in its release process. **containerd**
has essentially no perf CI. The shared shape across all studied
projects: *periodic trend-tracking first, release gating for what
proves stable, per-PR gating never*.

## Design

Three stages, each independently useful:

**Stage 1 — make the harness CI-runnable.** Headless Locust
(`--headless` with fixed user count, spawn rate, duration);
kind-compatible deployment path (the harness already sits behind
`hack/install-ate.sh --deploy-benchmarks`; the CI path must not
require the interactive UI or cloud-project env vars); CSV results
out. This is the one deep-focus engineering block in the whole CI
rollout — schedule it as a contiguous ~2–3 week chunk.

**Stage 2 — scheduled perf periodic.** A nightly (or initially
weekly) job inside the periodic tier
([ci-cuj-integration-testing.md](./ci-cuj-integration-testing.md)):
stand up kind, deploy a fixed workload mix, run a fixed-duration load
profile, and upload results as SHA-keyed artifacts (cilium's export
pattern, with artifacts standing in for the results bucket). The same
run records micro-VM lifecycle latencies — snapshot/restore/
resume-from-pause are already exercised by `internal/e2e/suites/demo`
and should be captured as numbers even before Locust-driven load is
wired up.

**Stage 3 — stable-SLO gating, release-blocking only.** After ~a
month of baseline, add automated failure for stable SLOs only: error
rate, plus a generous p99 latency envelope (sig-scalability's rule —
noisy metrics inform humans, stable metrics fail runs). The job then
joins the release-blocking checklist
([ci-cuj-stability-alerting.md](./ci-cuj-stability-alerting.md)). It
never becomes merge-blocking: that is the strongest position any
studied project holds, at any scale.

The known failure mode is baseline curation: an envelope so wide it
never fires, or so tight it cries wolf — which is exactly why gating
waits for a settled baseline (calendar time, not engineer time).

## Milestones

| # | Deliverable | Priority | Attention cost | Depends on |
|---|---|---|---|---|
| P1 | Headless/kind CI mode for the Locust harness | P2 | ~2–3 weeks contiguous | — |
| P2 | Scheduled perf periodic with SHA-keyed artifacts + lifecycle latencies | P2 | included in the P1 block | nightly periodic scaffolding |
| P3 | Stable-SLO failure + entry into release-blocking checklist | P2 | ~2 days | ~1 month of P2 baseline |

Costs: one kind cluster + load run per night (~30–60 min of runner
time); maintenance is baseline curation.

Exit criteria: two weeks of green perf periodics; a documented
baseline; an intentionally-introduced regression (e.g. an artificial
delay in a scratch branch of the harness) demonstrably caught by the
SLO check.
