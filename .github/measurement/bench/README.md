# ci-bench: equal-work Kyverno conformance comparison

This tree runs the same pinned Kyverno conformance test suite (commit
`945ac9ce`, i.e. v1.18.2) against two ways of provisioning the cluster under
test: upstream's own `kind`-based workflow, and a lightweight VM-clone
substrate ("substrate G", referred to elsewhere as the guest). The goal is a
resource-accounting comparison on standard hosted GitHub Actions runners, not
a benchmark of either tool's internals.

## Arms

| Workflow | Arm | What it runs |
|---|---|---|
| `ci-bench-ap.yaml` | A-practical | Upstream's own conformance workflow definitions, unchanged (same composite action, image-build job included), restricted to the frozen protocol's Kubernetes matrix row (v1.35.1) instead of the full 3-version matrix. Runs all 885 directories the 73 selected job/shard rows cover, included and excluded alike. This is the practical upstream baseline, reported separately from the equal-work arms below. |
| `ci-bench-a.yaml` | A | The same 73 job/shard rows, restricted to this tree's 839 included directories: one fresh kind cluster per shard (`hack/p82-kind/up.sh`, `kind` v0.32.0 / `kindest/node:v1.35.5`), `bin/p82-kind-sweep -ci-shard/-ci-dirs-file` runs exactly that shard's included directories through one chainsaw invocation (`--fail-fast=false`, D2). Substrate + job-graph cost of doing the equal amount of work. |
| `ci-bench-b.yaml` | B (drop-in) | Same 73 jobs and shard assignment as A, but each job restores its cluster from substrate G's baseline (`p82-sweep -hold -kubeconfig-out`) instead of building a `kind` cluster, then runs chainsaw directly against that job's explicit included-directory list (the same `plans/a/<job>.dirs` files A uses — not a shard-index/quarantine restriction, which can silently move a test across a shard boundary). Isolates the substrate's savings from the job-graph reorganization below. |
| `ci-bench-c.yaml` | C | 8 workers x 2 concurrent clones, one isolated clone restored per directory (no shared cluster), one Chainsaw process per directory. LPT-balanced by prior per-directory duration. Substrate + workflow reorganization together. |
| `ci-bench-c4.yaml` | C4 | Same as C with 4 workers x 2, to test the "about four workers" sizing question. Reported separately from C. |

Every workflow name starts with `ci-bench` (required by the anonymous hosted
repo's publish check) and triggers on a push to `bench/<arm>-cold` or
`bench/<arm>-warm` (branch suffix selects the cold/warm condition), plus
`workflow_dispatch`. All five share one concurrency group
(`ci-bench-hosted`, `cancel-in-progress: false`) so they never compete for the
account's concurrent-job limit.

## Cold vs warm

The condition is read from the branch suffix (`endsWith(github.ref_name,
'-warm')`); a cold branch's workflow never touches `actions/cache` at all —
not even to check.

- **Cold**: A pulls the pinned `kindest/node:v1.35.5` image fresh; B/C/C4
  build their baseline(s) in-job with no snapshot cache restore.
- **Warm**:
  - **A** restores a `docker save` tarball of the pinned `kindest/node`
    digest via `actions/cache`, keyed on that digest
    (`kindest-node-v1.35.5-ce977ae6`); on a miss it `docker save`s the image
    after `up.sh` pulls it, so the next warm run can `docker load` instead of
    pulling ~700 MiB.
  - **B** restores `/tmp/gh-snapshots` via `actions/cache`, keyed on
    `snap-<BUNDLE_SHA256>-<job id>`; **C/C4** key on
    `snap-<BUNDLE_SHA256>-<arm>-<worker id>` (a worker's baseline set is fixed
    by its plan). The Actions-level cache is content-addressed only by
    bundle+job/worker; the *harness's own* snapshot-cache key additionally
    folds in host CPU identity (`hostRestoreID`), so an Actions-level hit can
    still be a harness-level miss — that combination is exactly a
    foreign-CPU entry, not a broken cache. Every warm job greps its
    `sweep*.log` for the harness's own `snapshot cache hit (KEY)` /
    `snapshot cache miss (KEY) — creating` line (`harness/snapshotcache.go`)
    and reports both signals (see the `cache` evidence kind below). B/C/C4
    keep `/tmp/gh-snapshots` (but not `/tmp/gh`) through their dispose step
    only when warm, so the post-job `actions/cache` save step has something
    to persist on a miss.

## Frozen inputs

- `manifest.jsonl`: one row per directory (885 rows, 839 `cls: included`),
  with fields `dir`, `job`, `baseline`, `cls`, `reason`. Generated from
  pinned, committed inputs; not hand-edited.
- `plans/a/*.dirs`: one file per job/shard id, the exact included conformance
  directories that job runs — used directly as `-ci-dirs-file` by A's
  `p82-kind-sweep` invocation and as an explicit chainsaw directory list by
  B, so neither arm relies on quarantining or moving a directory across a
  shard's boundary. `plans/a/jobs-restricted.json` is the 72 job/shard rows
  (of 73) that still cover at least one included directory, kept for
  reference (its `quarantined_tests` field is upstream's own, unmodified).
- `plans/ap-jobs.json`: the unmodified 73-row manifest (A-practical keeps
  every directory, no quarantine additions).
- `plans/c/w<i>/<baseline>.dirs`, `plans/c/workers.json`, `plans/c/plan.json`
  and the `c4` equivalents: the 8x2 / 4x2 worker assignments, LPT-balanced by
  median prior per-directory duration (falls back to the population median
  for a directory with no prior measurement; `plan.json` lists which ones).
  Baselines other than the primary one are packed onto worker 0 so no other
  worker pays more than one baseline build.
- `run-shards.py`: drives a small number of shards sequentially on one
  worker (used for provisioning smoke checks before a full campaign, not by
  the five arms above, which invoke the substrate directly per job).
- `phase.sh`: wraps one command, appends one wall-clock JSON record to
  `$EVIDENCE/phases.jsonl`, and re-exits with the command's status. Every
  explicitly timed span in these workflows goes through it.

## Evidence

Every job emits evidence to the job log only — no `actions/upload-artifact`.
Each record is one line:

```
BENCH-EVIDENCE <kind> <compact-json>
```

Kinds and their fields:

| kind | fields |
|---|---|
| `profile` | `runner`, `image_os`, `image_version`, `kernel`, `architecture`, `workflow`, `job`, `sha`, `run_id`, `run_attempt`, `logical_cpus`, `ram_bytes`, `workspace_free_disk_bytes`, `kvm_device_present`, `kvm_read_write_access` (from the `capture-runner` action) |
| `phase` | `phase`, `start_unix_ns`, `end_unix_ns`, `wall_ms`, `exit`, `job`, `run_id`, `run_attempt` (from `phase.sh`; a raw `phases.jsonl` line is also acceptable, same fields) |
| `result` | `dir`, `bucket` (pass / fail / timeout / error / not-run), `job`, `baseline` (from a `result-*.jsonl` row) |
| `cache` | `arm`, `key` (the `actions/cache` key), `baseline` (C/C4 only), `hit` (bool, `actions/cache`'s own hit), `harness_hit` (bool or `null`; parsed from the harness's own snapshot-cache log line, B/C/C4 only), `harness_line` (the raw log line, empty if none seen), `reason` (free text; see "Cold vs warm" for what each arm keys on and how to read `harness_hit=false` with `hit=true`) |
| `versions` | `chainsaw`, `helm`, `kubectl_client`, `kind` (when applicable), `kubernetes_server` |

A collector reconstructs per-run accounting (submission-to-completion,
makespan, runner-minutes, allocated vCPU-minutes, peak overlap, per-phase
sum/median/max, per-directory outcomes) entirely from these lines plus the
Actions run/job/attempt metadata — no other artifact store is read.

## Departures from upstream (D1-D9)

| # | Departure | Applies to | Reason |
|---|---|---|---|
| D1 | Chainsaw v0.2.15 release, not upstream's v0.2.15-beta.3 | all arms, incl. A-practical | v0.2.15's JSON report format is what the collectors and this tree's plans were built against; keeping it uniform avoids a format-dependent confound |
| D2 | `failFast` forced off | A, B, C, C4 | equal work: a shard's first failure must not skip the rest; A-practical keeps upstream's own per-process `failFast` |
| D3 | Excluded directories not run | A, B, C, C4 | see the frozen manifest's exclusion classes (external image/trust, in-cluster network calls, cleanup-controller envelope, unpinned CRDs, upstream-inactive); A-practical runs them, reported separately |
| D4 | `kubectl-evict` pinned to a fixed release, installed once per worker | all arms | upstream installs it unpinned (`go install ...@latest`) per job |
| D5 | Webhook Service to URL rewrite plus a guest kubelet reverse proxy | B, C, C4 | substrate G's own admission-webhook mechanics; invisible to the test directories themselves |
| D6 | Per-directory isolated clone instead of one shared cluster per shard | C, C4 | the measured workflow reorganization |
| D7 | hugetlbfs-backed restores, including the baseline builder | B, C, C4 | required for acceptable per-clone restore cost on nested-virt hosted runners without hardware dirty-page logging |
| D8 | Kubernetes v1.35.5 instead of the matrix's v1.35.1 | A, B, C, C4 | the guest's own pinned version; both substrates then run the same version |
| D9 | Released, pinned container images; no from-source image-build job | A, B, C, C4 | the build job is identical work regardless of substrate; A-practical keeps it and is reported separately |

## Known gaps in this commit

- A-practical's image-build job assumes `make docker-save-image-all` still
  produces a single `kyverno.tar` at the pinned commit, as
  `comment-conformance.yaml` did; not independently re-verified here.
- The `kindest/node:v1.35.5` digest A/warm keys on
  (`sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95`)
  is `hack/p82-kind/up.sh`'s own default; not re-verified against the current
  kindest registry contents from this offline build.
