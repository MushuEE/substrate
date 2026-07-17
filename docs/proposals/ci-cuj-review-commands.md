# Proposal: CUJ — Review Commands and Merge Gating

Status: draft for discussion
Part of: [ci-testinfra-architecture.md](./ci-testinfra-architecture.md)

## The journey

1. A reviewer finishes reading a PR and signals "code looks good"
   (`/lgtm`) without needing merge rights.
2. A maintainer signals holistic approval (`/approve`) and from that
   point nobody babysits the PR: it merges automatically once checks
   are green, tested against current `main`.
3. Anyone with standing can rerun failed CI (`/retest`) without write
   access and without asking a maintainer to click buttons.
4. Anyone with standing can stop a merge (`/hold`) pending an
   unresolved discussion, and release it (`/unhold`).

Today none of this journey is supported: branch protection on `main`
enforces zero required status checks, merges are manual, a
stale-but-green PR can land against a `main` it was never tested
with, and contributors without write access cannot rerun a flaked
job.

## Studied practice

**Kubernetes** implements this journey with Prow: the `lgtm` and
`approve` plugins turn comments into labels, OWNERS files scope who
may apply them, and Tide merges automatically while maintaining one
invariant — every PR is tested against the most recent base-branch
commit before merge, so two individually-green PRs that conflict
logically cannot break `main`
([Tide docs](https://docs.prow.k8s.io/docs/components/core/tide/),
[approve plugin](https://docs.prow.k8s.io/docs/components/plugins/approve/approvers/)).
The two-command split exists because review capacity limits project
velocity: `/lgtm` is a low-barrier tier that grows the reviewer pool;
`/approve` is the high-trust gate
([OWNERS guide](https://github.com/kubernetes/community/blob/main/contributors/guide/owners.md)).

**containerd** gets the Tide invariant without Prow: the native
GitHub merge queue re-runs required checks on a merge-group SHA
containing the latest base plus queued PRs ahead
([merge queue docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue));
approval is ordinary GitHub review, with the two-LGTM rule enforced
by governance rather than bots
([containerd governance](https://github.com/containerd/project/blob/main/GOVERNANCE.md)).

**cilium** merges manually but blocks mergeability mechanically:
maintainer's-little-helper fails a required context while any
`dont-merge/*` label is present (missing sign-off, missing
release-note label, explicit holds) — labels as merge blockers
without Prow
([cilium/github-actions](https://github.com/cilium/github-actions)).
Reruns are cheap because the Ariane bot re-triggers workflows from
comments.

**etcd** uses Prow's `lgtm`/`approve`/`trigger` (free `/retest`) but
no merge automation — a maintainer merges manually on green.

The Prow-emulation actions available for plain GitHub (single
root-level OWNERS file, comment-driven labels) are chat-ops
conveniences, not enforcement: real gating still comes from branch
protection, so Substrate should not adopt them as a gating layer
(see anti-recommendations in the umbrella doc).

## Design

### Command-to-mechanism mapping

Each Prow command maps to a GitHub-native mechanism; only `/retest`
and `/hold` need small new workflows.

| Command | Mechanism | Who | Enforcement |
|---|---|---|---|
| `/lgtm` | Ordinary GitHub approving review. From a Reviewer (Triage access per `GOVERNANCE.md`) it is advisory — GitHub only counts write-access approvals toward protection rules, which matches the governance rule that Reviewers cannot merge | Reviewers+ | Social (visible signal) |
| `/approve` | Approving review from a Maintainer (write access) — satisfies the ruleset's required review | Maintainers | Ruleset |
| merge | Maintainer clicks "Merge when ready": the PR enters the merge queue and lands only after required checks pass on the merge-group SHA — the Tide invariant, natively | Maintainers | Merge queue |
| `/retest` | New small workflow on `issue_comment`: if the commenter is a Maintainer/Reviewer (team membership check), call the Actions API to re-run failed jobs on the PR's head SHA. Human-invoked rerun is allowed; automatic retry of failed tests is banned by the flake policy ([flaky-tests.md](https://github.com/kubernetes/community/blob/main/contributors/devel/sig-testing/flaky-tests.md); see [ci-cuj-stability-alerting.md](./ci-cuj-stability-alerting.md)) | Reviewers+ | n/a |
| `/hold`, `/unhold` | New small workflow applying/removing a `do-not-merge/hold` label, plus a `merge-blockers` job that fails a required context while any `do-not-merge/*` label is present (cilium's MLH pattern) | Reviewers+ | Ruleset (via the blocker context) |

### Merge gating configuration

- One aggregate gate job in `.github/workflows/pr-workflow.yaml`
  covering the unit/verify job and the E2E matrix behind a single
  fixed-name context. The existing `e2e-test` job already implements
  the correct pattern (`needs:` + `if: always()` + fail unless
  results are `success`) — this guards against GitHub counting a
  *skipped* required check as passing
  ([required-checks troubleshooting](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks));
  it needs to be extended to cover `run-tests` too, so the required
  context list never changes as jobs evolve (containerd's stated
  rationale for its equivalent `results` job).
- Ruleset on `main`: require the gate context, the CLA check, the
  `merge-blockers` context, and one maintainer review; enable the
  merge queue.
- Add `merge_group:` to `pr-workflow.yaml` triggers. Caution from the
  platform docs: path filtering is unavailable for `merge_group`
  events and PR-metadata-dependent jobs can stall the queue — keep
  required workflows unconditional.
- If queue latency ever hurts, containerd's escape valve is to mark
  the slow E2E tier advisory inside the queue
  (`if: github.event_name != 'merge_group'`) while keeping it
  PR-blocking — not to weaken the PR gate.

### Explicitly not built

No OWNERS-file emulation, no label-driven auto-merge bot, no
requirement that `/lgtm`+`/approve` labels gate anything: enforcement
lives entirely in the ruleset and merge queue. The comment commands
are ergonomics on top, chosen so the workflow *feels* like the
Kubernetes journey contributors know, while the trust model stays
GitHub-native.

## Milestones

| # | Deliverable | Priority | Attention cost |
|---|---|---|---|
| R1 | Aggregate gate + ruleset + merge queue + `merge_group` trigger | P0 | ~2 days |
| R2 | `/retest` workflow | P1 | ~1 day |
| R3 | `/hold`–`do-not-merge/*` labels + `merge-blockers` required context | P1 | ~1 day |

Exit criteria: a red or stale PR cannot merge by any non-admin path;
one week of queue operation without a stuck entry; a Reviewer
successfully reruns a failed job and holds a PR without maintainer
intervention.
