# Scaling to 10M actors

This page is the growth path for Substrate's storage tier: how the
same architecture serves a 10-actor pilot and a 10-million-actor
deployment, what must change between those points, and — just as
important — what never changes. Find the tier that matches your
deployment, deploy what that tier requires, and watch the graduation
triggers that tell you when to move up.

Scope: the Valkey cluster and its direct posture (sizing, durability,
backups, configuration). How state moves through the tier is
[`lifecycle.md`](./lifecycle.md); what is deployed and how it's wired
is [`topology.md`](./topology.md); incident response is
[`operations.md`](./operations.md).

Three conventions used throughout:

- **Deployed today** vs. **required at tier N** — every requirement
  is labeled. The gap between the two is the hardening backlog, not
  an inconsistency.
- **Estimates are labeled with their basis.** Most numbers here are
  engineering estimates (allocator analysis, protocol math), not
  measurements of this system under load. They are good enough to
  size against and honest about their provenance.
- **Every graduation includes a validation gate** — the load test or
  drill that turns the next tier's estimates into observations
  *before* production traffic depends on them.

## The invariant architecture

**The 3-shard Valkey cluster is the floor and, for a long time, the
ceiling.** From 10 actors to 10M actors, the architecture is the same
3-primaries + replicas cluster described in
[`topology.md`](./topology.md); what scales is resources, replica
count, durability posture, and operational maturity — never the
shape. There is no "small mode" to outgrow and no migration event
anywhere inside the envelope.

Three shards is deliberate, not just the bootstrap default:

- Per-shard heaps stay small at every tier (~2.5–3.5 GB even at 10M),
  which keeps `BGSAVE`/`BGREWRITEAOF` forks in the
  tens-of-milliseconds range and copy-on-write spikes trivial. The
  operationally painful fork-stall regime documented by large Redis
  operators starts an order of magnitude higher.
- Blast radius per shard is 1/3 of actors; rolling upgrades touch a
  third of the data at a time.
- There is headroom to ~30–50 M actors by *online resharding* before
  anything structural changes (see "Beyond the envelope").

More shards at small scale buy nothing except more failovers and more
operational objects. The one exception: the **strict durability
profile** pairs with 6 primaries to halve per-shard write rate (see
"Durability contract").

## Workload model

The sizing below assumes an agentic duty-cycle workload. All values
are estimates — stated so they can be checked against reality as the
deployment grows, and revised when they disagree.

| Parameter | Planning value | Basis |
|---|---|---|
| Registered actors | up to 10 M | the supported envelope |
| Active + paused fraction | 1–5 % → 100–500 k | duty-cycle assumption; sizing uses the 500 k ceiling |
| Worker records | ≤ 500 k, typically far fewer | one per concurrently-active actor, upper bound |
| Sustained lifecycle ops | ~500–1 000/s at 10 M | 10 M actors × 2–4 suspend/resume cycles/day, plus create/delete |
| Burst (wake storm) | 10× sustained → ~10 k lifecycle ops/s | design point for the durability discussion |
| Valkey ops per lifecycle op | ~8–10 | protocol count: lock pair, reads, actor CAS, worker CAS |
| Cluster-wide Valkey ops at burst | ~10⁵/s | product of the above; comfortably inside 3 primaries' capacity |

## Capacity math

### Per-record footprint

Records are protojson blobs (see `cmd/ateapi/internal/store/ateredis`
package docs), plus Valkey's per-key overhead and allocator rounding.

- **Actor**: twelve scalar/string/enum fields plus two sub-messages
  (`SnapshotInfo` with realistic snapshot URIs, and the
  `worker_selector` labels map). Plan for **~650 B – 1 KB per actor**
  in primary memory. *Basis: allocator analysis of representative
  records; unvalidated against a loaded cluster.*
- **Worker**: smaller strings than an actor, but the record carries a
  `labels` map cached from its pool plus the `Assignment`
  sub-message. Plan for **~0.5–1 KB per worker**. *Same basis; label
  cardinality is the swing factor.*

### Dataset by tier

| Actors | Actor data | + workers, locks, buffers, ×1.3 fragmentation | Provision (across primaries) |
|---|---|---|---|
| 1 k | ~1 MB | negligible | any |
| 100 k | ~100 MB | ~1.2 GB total | ~2 GB |
| 1 M | ~1 GB | ~2.5 GB total | ~4 GB |
| 10 M | ~6.5–10 GB | ~10–13 GB total | ~12–16 GB |

The fixed ~1 GB line item (replication backlog, client and pub/sub
buffers, AOF-rewrite buffer) dominates at small tiers and disappears
into the noise at large ones.

**The AOF sizing rule**: the append-only file runs **2–3× the
dataset** between rewrites. PVCs must be sized for that multiple —
the deployed **1 Gi PVC fills under any sustained write load and
stalls the shard with no failure required**. This is the single
config item worth fixing at every tier including T0.

### Worker cache (per API-server pod)

Each API-server pod mirrors every worker record in memory
(`cmd/ateapi/internal/workercache`). Plan for ~0.5–1 KB per worker in
the cache map (proto + map overhead, labels included).

| Workers | Cache per pod | `ListWorkers` full sync |
|---|---|---|
| 1 k | ~1 MB | sub-second |
| 10 k | ~5–10 MB | seconds |
| 100 k | ~50–100 MB | tens of seconds |
| 500 k (ceiling) | ~250–500 MB | ~minutes |

The sync cost is paid at pod startup (before the gRPC listener
opens — the pod is simply not Ready during it) and during
post-disconnect resyncs. From ~100 k workers up: budget API-server
memory for the cache, keep readiness probes patient enough to cover
the sync, and never restart the whole API-server fleet
simultaneously.

## The tiers

| | **T0 · Pilot** | **T1 · Production** | **T2 · Scale** | **T3 · Envelope** |
|---|---|---|---|---|
| Actors | ≤ 1 k | ≤ 100 k | ≤ 1 M | ≤ 10 M |
| Workers | ≤ 50 | ≤ 5 k | ≤ 50 k | ≤ 100–500 k |
| Shards | 3 (invariant) | 3 | 3 | 3 (6 for strict profile) |
| Replicas/shard | 1 | 1 | 1–2 | 1 (standard) / 2 (strict) |
| Pod `maxmemory` / limit | 512 Mi / 1 Gi | 1 Gi / 2 Gi | 2 Gi / 4 Gi | 4 Gi / 6–8 Gi |
| PVC | 5 Gi | 10 Gi | 25 Gi | 25 Gi, regional class |
| Backups | none required | daily + one restore drill | ≤ 60 min + drill per release | 15–60 min + drill per release |
| Durability profile | best-effort | standard | standard | standard or strict |
| Ops maturity | none | config hardening set | + coordinated failovers | + sweeps, storm-tested |

### T0 — Pilot (≤ 1 k actors, ≤ 50 workers)

What the deployed manifests give you, minus one trap. **Required:**

- **PVC ≥ 5 Gi** (deployed today: 1 Gi). Even a pilot writes enough
  AOF to fill 1 Gi; the failure is a write stall that looks like a
  mystery outage.
- `maxmemory` set with `noeviction` (deployed today: unset — the pod
  grows until an opaque OOMKill instead of failing writes cleanly).

Everything else can wait. Loss posture: a lost shard loses that
third of the pilot's actors; acceptable by definition at this tier —
if it isn't, you are not at T0.

**Graduate to T1 when** real users or non-recreatable actors arrive.
That's a policy trigger, not a capacity one — T0's capacity headroom
is enormous.

### T1 — Production (≤ 100 k actors, ≤ 5 k workers)

The tier where the **config hardening set** becomes mandatory. All
items are labeled in the configuration ladder below; the set is:
required pod anti-affinity + zone spread, PodDisruptionBudgets,
`maxmemory`, `cluster-require-full-coverage no` with typed
slot-unavailable errors, PVC class/reclaim hardening, daily backups,
and gating `DebugClear` (deployed today: a standing one-RPC wipe of
the entire registry — see `operations.md` risks).

Why here and not later: **deployed today, full-coverage `yes` + no
anti-affinity + no PDB compose so that a single node event can pause
the entire control plane.** That trio is the highest-ROI fix set in
this handbook, and T1 is defined as the point where you can no
longer shrug it off.

**Validation gate:** perform one full restore from a backup into a
scratch cluster. A backup that has never been restored is a
hypothesis, not a capability.

**Graduate to T2 when** any of: actor count approaches 100 k;
sustained lifecycle ops exceed ~100/s; worker count approaches 10 k
(cache syncs move from seconds to tens of seconds); or backup-drill
duration starts flirting with your maintenance window.

### T2 — Scale (≤ 1 M actors, ≤ 50 k workers)

Same architecture, bigger pods, tighter operations. **Required, in
addition to T1:**

- Pod sizing per the tier table; backup interval ≤ 60 min; restore
  drill every release cycle.
- **Coordinated maintenance failovers** become procedure, not
  advice: every planned drain/upgrade uses the `CLUSTER FAILOVER`
  runbook in [`operations.md`](./operations.md). At T2 event
  frequency, skipping it converts routine maintenance into a
  recurring data-loss source.
- API-server memory budgeted for the worker cache; staggered
  restarts enforced by PDB/rollout policy.
- Watch pub/sub burst sources: a WorkerPool label edit publishes one
  event per worker in the pool — at 50 k workers that is a
  meaningful subscriber-buffer burst (see `operations.md`, "Missed
  pub/sub events").

**Validation gate:** a load test at 2× your observed peak lifecycle
rate, watching p99 write latency, subscriber-buffer drops, and AOF
disk headroom. This is the test that converts the workload-model
estimates into your numbers.

**Graduate to T3 when** actor count approaches 1 M, or you need to
offer users a stated durability contract (the moment the contract
below stops being an internal detail and becomes a promise).

### T3 — Envelope (≤ 10 M actors, ≤ 100–500 k workers)

The supported ceiling. **Required, in addition to T2:**

- Pod sizing per the tier table; 25 Gi regional-class PVCs with
  `Retain` reclaim everywhere.
- **Reconciliation sweeps** for stuck-transitional actors and
  orphaned worker claims. At T3 event rates, failovers are routine —
  stranded records must be re-driven mechanically, not by an on-call
  human reading the risks table.
- **The published durability contract** (next section), with the
  strict profile implemented if any user needs it.
- Backups every 15–60 min; restore drill every release (at 1–3 GB
  per shard, a drill is a sub-30-minute exercise — one of the
  genuine luxuries of this scale).

**Validation gate:** a wake-storm test at 10× sustained rate
(~10 k lifecycle ops/s) on the exact production topology — and, if
offering strict, the same storm on the strict profile (this is the
test most likely to fail; see the write-ceiling row in the contract).

## Durability contract

One misconception to retire before any tuning conversation:

> **`appendfsync always` closes the crash gap, not the failover
> gap.** It guarantees an acked write is on the *primary's* disk —
> but a failover promotes a **replica**, and replication is
> asynchronous regardless of fsync policy. A primary that fsyncs
> every write and then dies still takes its un-replicated tail with
> it. There is no fsync setting that yields RPO=0.
>
> The per-write lever that *does* address failover loss is `WAIT`:
> blocking a specific write until ≥1 replica has received it
> (~0.5–1 ms in-region, *protocol estimate*). fsync policy is
> per-server; `WAIT` is per-operation — so the writes that are
> irreplaceable (suspend finalization, actor creation) can be
> protected individually without taxing the hot path.

Two deployment profiles. **Deployed today is neither** — it is
standard minus backups and minus the coordinated-failover procedure;
strict additionally requires store-layer `WAIT` support that does not
exist yet.

| | **standard** (default) | **strict** |
|---|---|---|
| AOF | `everysec` | `always` |
| Replicas per shard | 1 | 2 |
| `min-replicas-to-write` / `min-replicas-max-lag` | unset | `1` / `10` |
| Store-level `WAIT 1` on suspend-finalize + create | no | yes *(not implemented)* |
| Primaries | 3 | 6 (halves per-shard write rate) |
| Loss on primary **crash** | ≤ 1 s of acked writes | none (on disk) |
| Loss on unplanned **failover** | replication tail (ms–s) | bounded by max-lag; **none** for suspend/create (WAIT'd) |
| Loss on planned failover (coordinated) | none | none |
| Hot-path write latency | ~0.1 ms | ~1–5 ms on PD-class disks *(estimate)* |
| Per-shard write ceiling | ~50 k+/s | **~0.3–1 k/s** on PD-class disks (fsync serializes the event loop) *(estimate — the storm-test gate exists to measure this)* |

The strict profile's real price is that last row: at the T3 burst
point (~10 k lifecycle ops/s ≈ ~1.3 k writes/s/shard on 3 shards),
strict on PD-class disks sits at or above its fsync ceiling — hence
the 6-primary pairing, and hence the rule that **strict must pass
the storm test before being offered to anyone**. Local-SSD node
pools make fsync nearly free but sacrifice disk-survives-pod-loss
semantics — only acceptable with 2 replicas plus aggressive backups.

The contract worth publishing to users, either profile:

> Planned operations lose nothing. An unplanned primary failure may
> lose up to [1 s / max-lag] of the most recent acknowledged
> writes — except suspend and create acknowledgments in the strict
> profile, which survive any single failure. Whole-shard loss with
> backups configured is bounded by the backup interval, for that
> shard's third of actors.

Publish it as a stated property, not a discovered one. A durability
posture users learn about during an incident is a broken promise;
the same posture stated up front is an engineering trade.

## Configuration ladder

Every delta between the deployed manifests and the envelope, with
the tier where it becomes required.

| Setting | Deployed today | Required | From tier | Why |
|---|---|---|---|---|
| PVC size | 1 Gi | ≥ 5 Gi (T0/T1), 10 Gi (T2), 25 Gi (T3) | **T0** | AOF runs 2–3× dataset between rewrites; a full disk stalls writes with no failure required. |
| `maxmemory` | unset (grows to OOMKill) | ~75 % of pod limit, `noeviction` | **T0** | Writes fail with a clear error instead of an opaque OOMKill-and-replay cycle. |
| Pod anti-affinity / topology spread | none — primary and replica can share a node | required node anti-affinity per shard; zone spread | **T1** | One node event must not take a whole shard. The cluster-init job cannot compensate — its placement is IP-based and node-blind. |
| PodDisruptionBudget | none | `maxUnavailable: 1` per shard | **T1** | Voluntary evictions must never take a primary and its replica together. |
| `cluster-require-full-coverage` | `yes` (default) | **`no`** + typed slot-unavailable errors in the store layer | **T1** | With `yes`, any single-shard outage — including a routine failover window — pauses **all** writes cluster-wide. Partial availability is the right trade for a platform. |
| PVC class / reclaim | default class, default reclaim | regional-class storage, `Retain` reclaim + StatefulSet PVC retention | **T1** (class by T3) | Zonal disks die with their zone; `Retain` protects against namespace/StatefulSet-deletion accidents. |
| Off-cluster backups | none | replica `BGSAVE` → object storage; daily (T1) → ≤ 60 min (T2) → 15–60 min (T3) | **T1** | Turns whole-shard loss from *permanent* into *bounded by backup interval*. Runbook in `operations.md`. |
| `DebugClear` exposure | reachable in production builds | build-tag or break-glass gated | **T1** | One authenticated RPC currently equals total registry loss. |
| Upgrade / drain procedure | evictions race the gossip timeout | coordinated `CLUSTER FAILOVER` first | **T2** | Zero-tail-loss handoff; converts the most frequent loss event (planned maintenance) into a lossless one. |
| Reconciliation sweeps | none | stuck-transitional + orphaned-claim sweeps | **T3** | At envelope event rates, stranded records must be re-driven mechanically. |
| Strict profile (`always` + 2 replicas + `min-replicas-*` + `WAIT`) | not implemented | per the contract table | **T3** (optional) | Only if a user needs suspend/create acks to survive any single failure. |
| Pub/sub → `SPUBLISH`/`SSUBSCRIBE` | broadcast | migrate only past ~50 primaries | beyond envelope | Broadcast amplification is a scaling-curve concern, not a 10M concern. |

## Beyond the envelope

The edges of the 10M envelope, with observable triggers:

- **~30–50 M actors**: reshard 3 → 6–12 primaries. Online,
  gigabyte-scale slot migration — routine, no architecture change,
  no downtime. Trigger: provisioned dataset approaching per-shard
  `maxmemory` headroom.
- **~100 M actors**: this architecture should be **re-evaluated
  rather than stretched**. Per-shard heaps or shard counts re-enter
  the regimes that hurt: fork stalls at multi-GB heaps,
  multi-minute restores, meaningful gossip and pub/sub
  amplification, and RAM economics that climb linearly with a
  dataset that is mostly cold. The storage layer's seam
  (`cmd/ateapi/internal/store`, `Interface`) is what keeps that
  future re-evaluation a backend swap rather than a rewrite.
- **Signals to watch before any actor-count trigger**: sustained
  fsync-ceiling saturation in the strict profile; backup/restore
  drill duration creeping past the maintenance window; failover
  frequency × observed tail-loss size exceeding what the published
  contract promises.

## Gap checklist

Rollup of everything above that is not deployed today, in rough
order of ROI. Items marked **T0/T1** are the pre-production set.

- [ ] PVC resize 1 Gi → ≥ 5 Gi (T0)
- [ ] `maxmemory` + `noeviction` (T0)
- [ ] Required node anti-affinity + zone topology spread (T1)
- [ ] PodDisruptionBudget per shard (T1)
- [ ] `cluster-require-full-coverage no` + typed slot-unavailable
      error mapping in the store layer (T1)
- [ ] Backup CronJob (replica `BGSAVE` → object storage) + restore
      runbook + first drill (T1)
- [ ] `Retain` reclaim + StatefulSet PVC retention (T1)
- [ ] Gate `DebugClear` behind a break-glass flag (T1)
- [ ] Coordinated-failover drain procedure adopted for all planned
      maintenance (T2)
- [ ] Load test at 2× observed peak (T2 gate)
- [ ] Regional-class PVCs (T3)
- [ ] Reconciliation sweeps: stuck-transitional, orphaned-claim (T3)
- [ ] Wake-storm load test at 10× sustained (T3 gate)
- [ ] Strict profile implementation + storm test (T3, optional)
