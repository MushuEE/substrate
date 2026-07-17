# Proposal: CI and Test-Infrastructure Architecture (Overview)

Status: draft for discussion

## Summary

Substrate's CI today runs meaningful tests but enforces nothing:
`.github/workflows/pr-workflow.yaml` (unit + verify, and a kind E2E
matrix covering gVisor and micro-VM runtimes on KVM-enabled hosted
runners) is advisory, because branch protection on `main` requires
zero status checks. There is no merge queue, no ownership routing, no
flake policy, no performance signal, and no definition of what blocks
a release.

This proposal set studies how Kubernetes solves each concern at
maximal scale (Prow, Tide, OWNERS, TestGrid, release-blocking
dashboards, sig-scalability perf gating) and how three right-sized
CNCF projects — containerd, etcd, cilium — solve the same concerns
without that machinery. The headline conclusion: **Substrate should
build GitHub-native equivalents of the Prow concepts, not Prow
itself.**

This document is the umbrella: the comparator study, the gap
analysis, the shared test-tier vocabulary, the anti-recommendations,
and the single-SWE rollout plan. The design detail lives in one
proposal per critical user journey (CUJ):

| CUJ doc | Journey |
|---|---|
| [ci-cuj-review-commands.md](./ci-cuj-review-commands.md) | `/lgtm`, `/approve`, `/retest`, `/hold`; required checks, merge queue, tested-against-HEAD merges |
| [ci-cuj-integration-testing.md](./ci-cuj-integration-testing.md) | Test tiers and budgets, the presubmit E2E matrix, KVM constraints, nightly periodic against `main` |
| [ci-cuj-review-assignment.md](./ci-cuj-review-assignment.md) | CODEOWNERS + teams auto-assignment, owner-gated approval, advisory LLM review |
| [ci-cuj-stability-alerting.md](./ci-cuj-stability-alerting.md) | Flake policy and quarantine, CI-health alerting (failures + staleness), release go/no-go criteria |
| [ci-cuj-perf-regression.md](./ci-cuj-perf-regression.md) | CI-runnable `benchmarking/` Locust harness, perf trend tracking, stable-SLO release gating |

## Projects studied

| Project | Scale posture | CI platform | Merge automation |
|---|---|---|---|
| kubernetes/kubernetes | Maximal | Prow (presubmit/postsubmit/periodic) | Tide merge pools + batch testing |
| containerd/containerd | Right-sized | GitHub Actions (+ residual Prow periodics for k8s-ecosystem visibility) | GitHub merge queue; slowest jobs advisory in queue |
| etcd-io/etcd | Right-sized | Prow presubmits/periodics on shared k8s clusters; GHA for bots only | None — maintainer merges manually on green |
| cilium/cilium | Right-sized | GitHub Actions + Ariane trigger bot | None — committer merges; ~35 required contexts |

The three comparators occupy three points on the spectrum, which is
what makes the right-sizing argument concrete. etcd — the only one
running Prow — does so because SIG-etcd membership makes Kubernetes'
shared build clusters and TestGrid free
([etcd-io/etcd#18136](https://github.com/etcd-io/etcd/issues/18136)).
Substrate's constraints — small contributor base, single repo, public
runners that already expose `/dev/kvm` — put it at the GitHub-native
end. Two findings recur across every CUJ:

- **KVM E2E on free hosted runners is established practice**
  (containerd via Lima/QEMU, cilium via little-vm-helper), so
  Substrate's micro-VM matrix stays presubmit on hosted runners.
- **Every comparator rebuilt only the Prow concepts it needed** as
  small GitHub-native pieces (merge queue ≈ Tide's invariant,
  aggregate gate job ≈ required-job masking, CODEOWNERS ≈ OWNERS,
  labels + a tiny bot ≈ plugins) and skipped the rest.

## Test-tier vocabulary

Shared vocabulary used by all CUJ docs; definitions, budgets, and
placement rationale live in
[ci-cuj-integration-testing.md](./ci-cuj-integration-testing.md).

| Tier | Trigger | Contents | Budget |
|---|---|---|---|
| 0 — fast presubmit | every PR push | `go test ./...`, `hack/verify-all.sh` | ≤10 min |
| 1 — presubmit E2E | every PR push | existing kind matrix: gVisor + micro-VM × {mtls, jwt} | p75 ≤45 min |
| 2 — merge queue | `merge_group` | initially identical to 0–1 | same |
| 3 — periodic | nightly vs `main` | extended matrix, soak, perf, govulncheck | none (non-blocking) |
| 4 — release-blocking | at release cut | checklist over tiers 0–3 history | n/a |

## Gap analysis

| Concern | Substrate today | Target | Effort | CUJ doc |
|---|---|---|---|---|
| Merge gating | Zero required checks; manual merges of possibly-stale PRs | Required contexts + merge queue | S | review-commands |
| Review commands | None; contributors can't rerun CI | `/retest`, `/hold` workflows; native approvals for `/lgtm`, `/approve` | S | review-commands |
| Trigger tiers | Presubmit + cache-warming cron mixed in one workflow; no periodic E2E vs `main` | Explicit tier convention + nightly periodic | S | integration-testing |
| Review routing | No CODEOWNERS; `GOVERNANCE.md` ladder unenforced | CODEOWNERS + teams + lint; LLM review advisory-only | S–M | review-assignment |
| Flake management | Nothing | Policy doc, `ci/flake` label, quarantine ladder; later auto-detection | S policy, M automation | stability-alerting |
| Signal aggregation | Actions UI only; crons can rot silently | CI-health auto-issue (consecutive failures + staleness) | M | stability-alerting |
| Release criteria | No releases, no criteria | One-page go/no-go checklist, written before the first release | S | stability-alerting |
| Perf gating | `benchmarking/` interactive-only, never in CI, no baseline | Headless Locust periodic → stable-SLO release gate | M–L | perf-regression |
| Soak testing | E2E covers one lifecycle pass per run | Periodic soak cycling pause/resume/snapshot | M | integration-testing |
| Vuln scanning | Scheduled + push-to-main (`govulncheck.yaml`) | Keep periodic (CVE publication must not redden open PRs) | S | integration-testing |

## Anti-recommendations

Machinery Substrate should **not** adopt yet, and what would change
the answer.

| Don't adopt | Why not now | Revisit when |
|---|---|---|
| Prow + Tide | Requires operating a k8s CI control plane; every needed capability has a GitHub-native equivalent | Multi-repo org with shared CI needs, or umbrella membership makes hosted Prow free |
| OWNERS files + approve/lgtm enforcement or emulators | Needs Prow to enforce; GitHub emulators gate nothing; CODEOWNERS suffices while approver-set ≈ maintainer-set | >~20 regular reviewers across >3 areas with genuinely divergent approver sets |
| TestGrid instance | Curation overhead exceeds job count; its two alert conditions fit in ~100 lines against the Actions API | Periodic jobs outgrow one CI-health issue (~15–20 jobs), or jobs should publish to testgrid.k8s.io |
| Custom trigger bot (Ariane-style `/test`) | Comment-gating exists to steward paid cloud clusters; Substrate's E2E is free on hosted runners | E2E hits real cloud infra with per-run cost |
| Batch merge testing / queue tuning | Batching amortizes hours-long suites over hundreds of daily merges | Sustained >15–20 merges/day with queue wait rivaling presubmit latency |
| Self-hosted runners / dedicated clusters for E2E | KVM-on-hosted is proven (containerd, cilium, Substrate's own matrix); self-hosting adds security + maintenance burden | A test needs >1 node's resources, real cloud networking, or hardware hosted runners lack |
| Per-PR perf gating | Perf data too noisy to gate merges even at Kubernetes scale | Never, on current evidence; end state is stable-SLO release gating |
| Antithesis-style deterministic simulation / robustness suite | High-investment; etcd built this for consistency guarantees after years of maturity | Persistence layer (`docs/proposals/hybrid-persistence-architecture.md`) hardens toward durability guarantees — then copy etcd's robustness track-record model |
| Multi-cloud conformance matrix | cilium runs EKS/GKE/AKS because cloud datapaths are its product; Substrate's surface is kernel/hypervisor-local, covered by kind+KVM | Managed-cloud integrations with provider-specific behavior ship |

## Rollout: single-SWE execution plan

Resourcing constraint: roughly one engineer, part of whose calendar
is review latency, not coding. Two planning principles:

- **The scarce resource is engineer attention, not runner minutes or
  calendar time.** Work that consumes calendar but no attention —
  nightly-run history, perf baselines — starts as early as possible,
  even though its consumers ship last.
- **There is exactly one deep-focus block** (the Locust harness,
  perf-regression P1). Everything else is configuration, workflow
  authoring, or policy writing that tolerates interruption. Protect
  the block; interleave consensus-bound docs into its gaps.

### Swimlanes

One engineer serially multiplexes lanes 1–4; lane 0 runs unattended.

| Lane | Nature | Contents |
|---|---|---|
| 0 — data accrual | zero attention, calendar-bound | nightly history, perf baseline; gates S3, P3, S2 usefulness |
| 1 — platform config | small, needs admin rights | rulesets, merge queue, teams, labels |
| 2 — workflow authoring | core GHA engineering | gate job, `merge_group`, nightly periodic, `/retest`, `/hold`, lint, health job |
| 3 — policy and docs | consensus-bound | CI policy doc, release criteria, area boundaries |
| 4 — harness engineering | one contiguous deep block | Locust headless/kind, lifecycle latencies, SLO check |

### Cross-CUJ milestone order

Milestone IDs refer to the tables in each CUJ doc.

| Order | Milestone | CUJ doc | Priority | Attention cost |
|---|---|---|---|---|
| 1 | R1 — gate + ruleset + merge queue | review-commands | P0 | ~2 days |
| 2 | T1 — nightly periodic (starts lane 0) | integration-testing | P0 | ~2–3 days |
| 3 | R2, R3 — `/retest`, `/hold` | review-commands | P1 | ~2 days |
| 4 | S1 — CI policy doc + flake labels (start early; consensus overlaps other work) | stability-alerting | P1 | ~2 days + latency |
| 5 | A1, A2 — CODEOWNERS decision + implementation | review-assignment | P1 | ~2–3 days + decisions |
| 6 | P1, P2 — Locust CI mode + perf periodic (protected block) | perf-regression | P2 | ~2–3 weeks |
| 7 | P3 — stable-SLO gate | perf-regression | P2 | ~2 days, after baseline |
| 8 | S2 — CI-health auto-issue | stability-alerting | P2 | ~3–4 days |
| 9 | S3 — flake auto-filing; A3 — advisory LLM review | stability-alerting, review-assignment | P3 | ~3 days; optional |

Total attention cost ≈ **6–8 SWE-weeks spread over ~a quarter**,
because S2/S3/P3 consume lane-0 calendar time that elapses while the
engineer works elsewhere. If the schedule slips, cut from the bottom:
A3 first (gates nothing, addable in an afternoon later), then S3.

### [RFC] tracking-issue draft

Ready to file as the umbrella issue; each CUJ becomes a sub-issue
tracking its own milestone table.

```markdown
# [RFC] Tiered CI and test-infrastructure rollout

**Status:** proposed
**Design:** docs/proposals/ci-testinfra-architecture.md (umbrella)
+ one proposal per CUJ (review-commands, integration-testing,
review-assignment, stability-alerting, perf-regression)
**Resourcing assumption:** ~1 SWE, ~6–8 SWE-weeks over ~1 quarter

## Problem

Substrate's CI runs meaningful tests (unit + verify, and a kind E2E
matrix covering gVisor and micro-VM runtimes on KVM-enabled hosted
runners) but enforces nothing: branch protection on `main` requires
zero status checks, merges are not retested against current HEAD,
there is no ownership routing, no flake policy, no performance
signal, and no definition of what blocks a release. GOVERNANCE.md
says "green CI before merge"; the platform does not enforce it.

## Proposal

Adopt GitHub-native equivalents of the Kubernetes test-infra
concepts, as practiced by containerd and cilium — not Prow itself.
Five CUJ sub-issues, each independently shippable:

- [ ] CUJ: review commands and merge gating (P0 core) —
      aggregate gate, ruleset, merge queue, /retest, /hold
- [ ] CUJ: CI tiers and integration testing (P0 core) —
      nightly periodic E2E + soak against main; tier budgets
- [ ] CUJ: automatic review assignment (P1) —
      CODEOWNERS + teams + lint; advisory-only LLM review (optional)
- [ ] CUJ: stability, dashboards, alerting (P1 policy, P2 tooling) —
      flake policy + quarantine ladder; CI-health auto-issue;
      release go/no-go criteria
- [ ] CUJ: performance regression tracking (P2) —
      headless Locust periodic from benchmarking/; stable-SLO
      release gating (never merge-blocking)

## Non-goals (see umbrella doc for revisit triggers)

Prow/Tide, OWNERS-enforcement emulation, a TestGrid instance, a
custom trigger bot, self-hosted runners, per-PR perf gating,
multi-cloud conformance. LLM-based PR review, if adopted, is
advisory-only and never a required check.

## Costs

Runner minutes are free (public repo); real costs are one extra full
CI run per merge (merge group), one nightly E2E matrix + one nightly
perf run of periodic compute, and a weekly triage habit. Maintenance
surface added: ruleset config, CODEOWNERS, three small workflows
(/retest, /hold, CI-health), two scheduled workflows.

## Requested from maintainers

1. Approval of tier definitions and latency budgets
   (ci-cuj-integration-testing.md).
2. CODEOWNERS area boundaries (ci-cuj-review-assignment.md).
3. Consensus on the flake policy doc
   (ci-cuj-stability-alerting.md) — the only contributor-facing
   process change in the set.
```

## Consolidated references

Kubernetes (maximal reference):

- Prow job types: <https://docs.prow.k8s.io/docs/jobs/>
- Tide: <https://docs.prow.k8s.io/docs/components/core/tide/>
- OWNERS: <https://github.com/kubernetes/community/blob/main/contributors/guide/owners.md>
- Flaky-test policy: <https://github.com/kubernetes/community/blob/main/contributors/devel/sig-testing/flaky-tests.md>
- Release-blocking criteria: <https://github.com/kubernetes/sig-release/blob/master/release-blocking-jobs.md>
- TestGrid configuration: <https://github.com/GoogleCloudPlatform/testgrid/blob/master/config.md>
- Scalability regression case studies: <https://github.com/kubernetes/community/blob/master/sig-scalability/governance/scalability-regressions-case-studies.md>

Right-sized comparators:

- containerd CI: <https://github.com/containerd/containerd/blob/main/.github/workflows/ci.yml>
- containerd governance: <https://github.com/containerd/project/blob/main/GOVERNANCE.md>
- etcd Prow jobs: <https://github.com/kubernetes/test-infra/tree/master/config/jobs/etcd>
- etcd Prow-migration rationale: <https://github.com/etcd-io/etcd/issues/18136>
- etcd robustness tests: <https://github.com/etcd-io/etcd/blob/main/tests/robustness/README.md>
- cilium CI guide: <https://docs.cilium.io/en/latest/contributing/testing/ci/>
- little-vm-helper: <https://github.com/cilium/little-vm-helper>
- cilium bots: <https://github.com/cilium/ariane>, <https://github.com/cilium/github-actions>

GitHub platform and review automation:

- CODEOWNERS: <https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners>
- Merge queue: <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue>
- Required-checks troubleshooting: <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks>
- Claude Code GitHub Action: <https://github.com/anthropics/claude-code-action>
- Kubernetes AI-assistance policy: <https://kubernetes.io/blog/2026/06/26/open-source-maintainership-in-the-age-of-ai/>

Substrate paths referenced across the set:
`.github/workflows/pr-workflow.yaml`,
`.github/workflows/govulncheck.yaml`, `hack/verify-all.sh`,
`hack/verify/`, `hack/run-e2e-kind.sh`, `hack/microvm-assets/`,
`internal/e2e/suites/`, `benchmarking/deploy_locust.sh`,
`benchmarking/monitoring.yaml`, `GOVERNANCE.md`, `CONTRIBUTING.md`.
