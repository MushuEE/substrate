# Proposal: CUJ — Stability, Dashboards, and Alerting

Status: draft for discussion
Part of: [ci-testinfra-architecture.md](./ci-testinfra-architecture.md)

## The journey

1. A maintainer can answer "is `main` healthy?" in under a minute,
   from one place, without paging through Actions runs.
2. A flaky test is *triaged* — labeled, tracked, quarantined with an
   owner — instead of rerun-until-green; the quarantine provably
   shrinks over time instead of becoming a graveyard.
3. Nobody discovers weeks later that a scheduled job silently stopped
   running: staleness alerts within hours.
4. Whoever cuts a release walks a written go/no-go checklist instead
   of negotiating criteria during the release crunch.

Today: signal is whatever the Actions UI shows; there is no flake
label, policy, or measurement; a dead cron (e.g.
`.github/workflows/govulncheck.yaml`) would rot silently; and with
zero releases cut so far, no release criteria exist — which makes now
the right time to write them, while they are policy rather than
negotiation.

## Studied practice

**Kubernetes — signal aggregation.** TestGrid computes per-job status
(PASSING / FAILING / FLAKY) over run history and alerts on two
conditions: N consecutive failures, and *staleness* — a job that
stopped producing results is a false green
([TestGrid config reference](https://github.com/GoogleCloudPlatform/testgrid/blob/master/config.md)).
"CI signal" is a curated, owned view, not raw statuses.

**Kubernetes — flake policy**
([flaky-tests.md](https://github.com/kubernetes/community/blob/main/contributors/devel/sig-testing/flaky-tests.md)):
CI jobs must **not** auto-retry failed tests — a race that "almost
never happens" happens regularly at thousands of runs, and retries
hide it. Flakes become `kind/flake` issues; a flaky merge-blocking
test may be quarantined only with a critical-urgent tracking issue
owned by the responsible SIG, then deflaked, reinstated, or deleted.

**Kubernetes — release criteria.** Release-*blocking* status is a
two-way contract with strict admission criteria (p75 runtime ≤120
min, ≥75% weekly pass rate, 3 consecutive green runs on one commit,
responsive owner, alerting configured), so a job may only hold a
release hostage if it is fast, frequent, reproducible, and owned
([release-blocking-jobs.md](https://github.com/kubernetes/sig-release/blob/master/release-blocking-jobs.md)).

**cilium** has the most transferable flake system: a documented
Flake / CI-Bug / Regression taxonomy, a `ci/flake` label with an
issue protocol, and a three-step quarantine ladder — (1) skip the
individual test, (2) drop the workflow from the required-context list
but keep it running as advisory, (3) last resort, remove the PR
trigger by reviewed PR while keeping the scheduled trigger so
rehabilitation can be observed with data; never disable via the web
UI, which leaves no audit trail
([cilium CI guide](https://docs.cilium.io/en/latest/contributing/testing/ci/)).

**etcd** automates detection: a daily job pulls TestGrid data over a
14-day rolling window and auto-files issues for flaky tests
(`scripts/measure-testgrid-flakiness.sh` in
[etcd-io/etcd](https://github.com/etcd-io/etcd)); TestGrid's
monitoring quality was a stated motivation for etcd's move to Prow
([etcd-io/etcd#18136](https://github.com/etcd-io/etcd/issues/18136)).

**containerd** is lighter-touch: run the integration suite twice per
job, skip individual tests with an inline tracking-issue link, render
per-test results into `$GITHUB_STEP_SUMMARY`, and demote the flakiest
jobs to advisory in the merge queue.

## Design

### Flake policy (document + labels; no new infrastructure)

A short CI policy doc (companion to `GOVERNANCE.md`) adopting:

- **No auto-retry** on required jobs (Kubernetes' rule). Human-
  invoked `/retest`
  ([ci-cuj-review-commands.md](./ci-cuj-review-commands.md)) is fine;
  `retry: N` in job config is not.
- **cilium's taxonomy and quarantine ladder**, adapted: `ci/flake`
  label + issue template (failing-run link, failure text pasted for
  searchability); quarantine = skip-with-issue or demote-to-advisory
  by reviewed PR only, scheduled run kept alive to observe
  rehabilitation.
- **Kubernetes' escrow rule scaled down**: a quarantined test must
  have an open issue owned by a maintainer; quarantine without an
  issue is reverted.

The E2E matrix's golden-snapshot waits and VM lifecycle operations
are exactly the kind of tests that will flake as coverage grows; the
policy should exist before the first bad week, not after.

### CI-health alerting (TestGrid's two conditions, sized down)

A scheduled job (~100 lines against the Actions API) that
auto-files/updates a single "CI health" issue when any periodic job
either fails K consecutive runs or has not produced a run in M hours
(the staleness condition). Generate the watched-job list from the
workflow files to avoid drift. Per-run summaries land in
`$GITHUB_STEP_SUMMARY` (containerd's pattern). Auto-filing per-test
flake issues (etcd's pattern) becomes worthwhile only after the
nightly periodic
([ci-cuj-integration-testing.md](./ci-cuj-integration-testing.md))
has accumulated ≥1 month of history.

A static dashboard page is deliberately out of scope until the
periodic job count outgrows what one issue can summarize (~15–20
jobs).

### Release criteria (Tier 4)

One page, in the CI policy doc:

- All presubmit-required jobs green on the release ref.
- ≥3 consecutive green nightly periodics (Kubernetes' "3 green runs"
  rule at nightly cadence).
- Perf periodic within its SLO envelope
  ([ci-cuj-perf-regression.md](./ci-cuj-perf-regression.md)), once it
  exists.
- No open `ci/flake` issues against quarantined release-relevant
  tests without a maintainer-approved waiver.

Release-*informing* (noted, not blocking): govulncheck, soak, any job
in its prove-in or rehabilitation period — a job must earn blocking
status through demonstrated stability. The Kubernetes "CI signal"
*role* scales down to a rotation-free habit: whoever cuts the release
walks this checklist, with the CI-health issue as the dashboard.

## Milestones

| # | Deliverable | Priority | Attention cost | Depends on |
|---|---|---|---|---|
| S1 | CI policy doc (flake policy + quarantine ladder + release criteria) + `ci/flake` label + issue template | P1 | ~2 days + consensus latency | — |
| S2 | CI-health auto-issue job (consecutive-failure + staleness) | P2 | ~3–4 days | nightly periodic exists |
| S3 | Per-test flake auto-filing from periodic history | P3 | ~3 days | ≥1 month of nightly history |

S1 is the only milestone in the whole rollout that changes
contributor-facing process; it needs maintainer consensus, so start
the doc early and let review latency overlap other work.

Exit criteria: first real flake triaged through the documented path
rather than ad-hoc rerun; a deliberately-disabled scheduled job is
flagged by S2 within M hours; the first tagged release is cut against
the written checklist.
