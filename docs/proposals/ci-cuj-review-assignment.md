# Proposal: CUJ — Automatic Review Assignment

Status: draft for discussion
Part of: [ci-testinfra-architecture.md](./ci-testinfra-architecture.md)

## The journey

1. A contributor opens a PR touching the micro-VM runtime; the right
   reviewers are requested automatically within seconds — no
   "who owns this?" round-trip.
2. A maintainer knows every merged PR was approved by someone who
   owns the touched area, enforced by the platform rather than by
   vigilance.
3. An optional advisory first-pass review (LLM-based) lands on every
   PR before a human spends time on it — flagging obvious issues,
   never gating.

Today: no `CODEOWNERS`, no auto-assignment, no enforcement that an
area owner approved. `GOVERNANCE.md` (draft) already defines the
Reviewer/Maintainer ladder and explicitly anticipates "a formal list
of Maintainers and per-area Reviewers (e.g., via `CODEOWNERS` ...)".

## Studied practice

**Kubernetes** maps ownership at directory granularity via in-repo
`OWNERS` files with a reviewer/approver split, auto-assignment
(blunderbuss), and per-OWNERS-file approval aggregation. Aliases live
in-repo rather than GitHub Teams "because changes to GitHub Teams are
not publicly auditable"
([OWNERS guide](https://github.com/kubernetes/community/blob/main/contributors/guide/owners.md)).
This machinery requires Prow.

**cilium** is the strongest CODEOWNERS practitioner: ~40 path-mapped
`@cilium/*` teams, a linter workflow validating the file, all
requested owner teams must approve, and the file's comment header
doubles as team-charter documentation (`CODEOWNERS` in
[cilium/cilium](https://github.com/cilium/cilium)).

**containerd** has neither OWNERS nor CODEOWNERS; its two-LGTM rule
is governance-enforced. This is the honest floor: at small scale,
social enforcement works — but it does not give auto-assignment.

CODEOWNERS' limitations versus OWNERS
([GitHub docs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)):
no reviewer/approver distinction, any single listed owner's approval
satisfies a pattern, last-matching-pattern-wins, owners must hold
write access, invalid entries silently dropped, and the file must be
owned by itself to prevent drive-by edits. At Substrate's contributor
count none of these bind: the approver set is approximately the
maintainer set.

On LLM review: every documented vendor pattern for
[claude-code-action](https://github.com/anthropics/claude-code-action)
posts comments rather than failing checks; no surveyed OSS project
makes an LLM review a required check; and Kubernetes' AI policy makes
the human contributor fully accountable for AI-assisted changes
([Kubernetes blog](https://kubernetes.io/blog/2026/06/26/open-source-maintainership-in-the-age-of-ai/)).
GitHub's required-approval model reinforces this: an LLM comment
cannot satisfy a required-review count.

## Design

- `CODEOWNERS` backed by GitHub teams, starting coarse and splitting
  only when expertise actually diverges. Proposed initial areas
  (maintainer decision required):
  - default: the maintainer team (catch-all `*` entry)
  - micro-VM runtime paths
  - API/proto surface
  - `hack/` + `.github/workflows/` (CI owns itself; also ensures the
    `CODEOWNERS` file itself is owner-gated)
- "Require review from Code Owners" in the ruleset on `main`.
- A CODEOWNERS lint job in fast presubmit (cilium's pattern):
  validates syntax and that every owner resolves — paying off the
  silent-drop failure mode.
- The Reviewer/Approver distinction stays where containerd keeps it:
  in `GOVERNANCE.md`, socially enforced. Reviewer approvals are
  visible signal; Maintainer approvals satisfy the ruleset. No OWNERS
  emulation (see umbrella anti-recommendations).
- Optional, last, and cut first if the schedule slips: advisory LLM
  review via `claude-code-action` posting comments only — a fast
  first pass that substitutes for some of what blunderbuss buys a
  small project, never for the Maintainer approval `GOVERNANCE.md`
  requires.

## Milestones

| # | Deliverable | Priority | Attention cost |
|---|---|---|---|
| A1 | Area-boundary decision (maintainers) | P1 | discussion, not code |
| A2 | CODEOWNERS + teams + ruleset toggle + lint job | P1 | ~2 days |
| A3 | Advisory LLM review workflow | P3 (optional) | ~half a day |

Exit criteria: every PR auto-requests the owning area's team; GitHub
team membership matches `GOVERNANCE.md`'s maintainer list; the lint
job fails on an unresolvable owner; (if A3 ships) LLM comments appear
on PRs while remaining absent from the required-context list.
