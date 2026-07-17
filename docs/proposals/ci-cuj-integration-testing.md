# Proposal: CUJ — CI Tiers and Integration Testing

Status: draft for discussion
Part of: [ci-testinfra-architecture.md](./ci-testinfra-architecture.md)

## The journey

1. A contributor pushes to a PR and gets fast feedback: lint/unit
   verdict within ~10 minutes, full E2E verdict (both sandbox
   runtimes, both auth modes) within ~45 minutes.
2. A maintainer trusts `main` continuously: a nightly run of the full
   suite against `main` means a regression or environmental drift
   (kind image, kata release, runner changes) is discovered within a
   day, not by the next unlucky PR.
3. Adding a new test suite has a known home: contributors know what
   earns a place in presubmit versus the nightly, and what the
   latency budget is.

Today steps 1 is real (`.github/workflows/pr-workflow.yaml`), but
nothing distinguishes tiers on purpose: presubmit, a cache-warming
postsubmit, and a weekly cron share one workflow; there is no
scheduled run of the E2E suites against `main`; and there is no
stated budget deciding what may join presubmit.

## Studied practice

**Kubernetes** splits jobs into presubmits (the merge gate),
postsubmits (per-commit artifacts/signal), and periodics (expensive
or environment-heavy testing on a schedule)
([Prow job docs](https://docs.prow.k8s.io/docs/jobs/)). The split
maps cost to signal need: every presubmit job worsens merge latency
and — through flakiness — merge odds for everyone, so anything not
needed to gate an individual PR moves down-tier.

**cilium** demonstrates the transferable version on GitHub Actions:
smoke tests auto-run per PR; the heavy platform suite is a separate
tier; an hourly scheduled workflow replays the full suite against
`main` and maintenance branches. Its kernel×k8s E2E matrix is
data-driven with a deliberately thinner PR slice and fatter scheduled
slice — same workflow, two matrix files
([cilium CI guide](https://docs.cilium.io/en/latest/contributing/testing/ci/)).
Crucially for Substrate, cilium boots QEMU/KVM micro-VMs with custom
kernels on standard hosted runners via
[little-vm-helper](https://github.com/cilium/little-vm-helper), and
**containerd** does the same with Lima/QEMU for its distro matrix
(`.github/workflows/ci.yml` in
[containerd](https://github.com/containerd/containerd)): KVM E2E on
free hosted runners is established presubmit practice, not a hack.

**etcd** runs ~25 cheap containerized presubmits on every PR and
pushes exotic architectures and 24-hour robustness runs to periodics
([etcd presubmit config](https://github.com/kubernetes/test-infra/tree/master/config/jobs/etcd)).

## Constraints that shape tier placement

- **KVM on hosted runners is proven.** Substrate already runs
  kata/cloud-hypervisor micro-VMs on free `ubuntu-latest` runners via
  a udev rule (`pr-workflow.yaml`), the same foundation as containerd
  and cilium. Micro-VM E2E stays presubmit; no self-hosted runners.
- **Runner disk (~14 GB free) is the binding resource**, already
  managed by the free-disk-space step and the micro-VM asset cache
  keyed on `hack/microvm-assets/assemble.sh`. Matrix growth
  multiplies per-job image pressure, which argues for growing the
  *periodic* matrix rather than the presubmit one.
- **Public-repo Actions minutes are free**; presubmit costs are
  wall-clock latency, runner concurrency, and flake surface.

## Tier definitions

**Tier 0 — fast presubmit (every PR push; budget ≤10 min).**
`go test ./...` and `hack/verify-all.sh` (the `hack/verify/`
scripts). Required via the aggregate gate (see
[ci-cuj-review-commands.md](./ci-cuj-review-commands.md)).

**Tier 1 — presubmit E2E (every PR push; budget p75 ≤45 min, hard
timeout 60 min).** The existing matrix: kind with `/dev/kvm`,
auth-mode {mtls, jwt}, gVisor + micro-VM suites via
`hack/run-e2e-kind.sh` over `internal/e2e/suites/`. The 45-minute p75
budget is a deliberate fraction of Kubernetes' 120-minute ceiling for
release-blocking jobs
([release-blocking criteria](https://github.com/kubernetes/sig-release/blob/master/release-blocking-jobs.md)).
When a proposed addition would blow the budget, it goes to Tier 3
instead; new suites join presubmit only while the budget holds.

**Tier 2 — merge queue (on `merge_group`).** Initially identical to
Tiers 0–1. Details and the advisory-in-queue escape valve are in
[ci-cuj-review-commands.md](./ci-cuj-review-commands.md).

**Tier 3 — periodic (nightly against `main`).** New scheduled
workflow:

- Full E2E matrix extended along axes excluded from presubmit: all
  suites × both runtimes × both auth modes, plus a soak variation
  (repeated suspend/resume/snapshot cycles) targeting the micro-VM
  state machine — the highest-risk surface with the least repetition
  in presubmit.
- Hosts the perf run once it exists
  ([ci-cuj-perf-regression.md](./ci-cuj-perf-regression.md)).
- The existing weekly cache-refresh cron and
  `.github/workflows/govulncheck.yaml` remain periodic residents.
  govulncheck stays out of the required presubmit set on purpose: a
  newly-published CVE must not redden unrelated open PRs (required
  checks should be deterministic with respect to the diff); an
  advisory presubmit run is optional later (etcd runs govulncheck
  presubmit).

Periodic failures block no one's PR; they feed the flake pipeline
and CI-health issue
([ci-cuj-stability-alerting.md](./ci-cuj-stability-alerting.md)).

**Tier 4 — release-blocking.** Defined in
[ci-cuj-stability-alerting.md](./ci-cuj-stability-alerting.md);
mechanically it is "presubmit set green on the release ref + N
consecutive green nightlies + perf within envelope".

## Milestones

| # | Deliverable | Priority | Attention cost |
|---|---|---|---|
| T1 | Nightly periodic workflow (extended matrix + soak variation), per-run results in the workflow summary | P0 | ~2–3 days |
| T2 | Tier convention documented (budgets, what earns presubmit) in the CI policy doc | P1 | included in policy doc |

T1 is deliberately early in the cross-CUJ rollout even though its
consumers (flake stats, release criteria) come later: run history is
calendar-bound, not attention-bound, so it should accumulate while
the engineer works elsewhere.

Exit criteria: nightly runs green (or triaged) for two consecutive
weeks; a deliberate revert-tested regression on `main` is flagged by
the next nightly; the tier budgets are written down and cited in at
least one review declining a presubmit addition.
