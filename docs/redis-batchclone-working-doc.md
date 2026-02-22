# Redis `doBatchClone` Working Notes

Date: 2026-02-21 (local run)
Branch: `cloneImprovements`
HEAD: `47e6338a`

## Status

- Redis batch clone implementation is present at `pkg/meta/redis.go:5061`.
- Base clone path now calls backend batch clone for non-directory entries during directory clone traversal.
- Old per-entry Redis clone path (`doCloneEntry`) still exists and remains fallback behavior when batch path returns `ENOTSUP`.
- This document is for local reference and does not require pushing to remote.

## Thesis

- Redis already had in-server clone per entry (`doCloneEntry`), but clone of large directories was still dominated by per-entry transaction/control overhead and per-entry round trips.
- The key optimization is to clone many non-directory entries in a single transactional unit per sub-batch, with pipelined read phase and pipelined write phase.
- This reduces control/read-modify-write command overhead by about 54% and end-to-end clone latency by about 94% in tested 5k/10k one-chunk workloads.

## What Was Changed

- PR-6656 baseline patch was applied first (local baseline alignment) to bring batch clone plumbing into this tree.
- Redis backend now implements `doBatchClone`.

Main touched files in this workspace:

- `pkg/meta/redis.go` (new batch clone implementation)
- `pkg/meta/base.go` (batch clone call path / concurrency wiring)
- `pkg/meta/interface.go` (Clone signature update with concurrency)
- `pkg/meta/sql.go` (SQL companion implementation from baseline patch)
- `cmd/clone.go`, `pkg/fs/fs.go`, `pkg/meta/base_test.go`, `pkg/meta/tkv.go`, `pkg/meta/utils.go`, `pkg/vfs/internal.go`

Implementation entry point:

- `pkg/meta/redis.go:5061`

## Clone Call Path (Current)

For clone of a directory in `base.go`:

1. `Clone(...)` validates source/destination, gets summary/quota, creates top destination node.
2. `cloneEntry(...)` traverses directory entries using `DirHandler` in batches.
3. For non-directory children in a batch, `BatchClone(...)` is called.
4. `BatchClone(...)` calls engine `doBatchClone(...)`.
5. If `doBatchClone(...)` returns `ENOTSUP`, caller falls back to per-entry `cloneEntry(...)`.

Relevant code:

- `pkg/meta/base.go:3182` (`Clone`)
- `pkg/meta/base.go:3249` (`cloneEntry`)
- `pkg/meta/base.go:3347` (`BatchClone` use + ENOTSUP fallback)
- `pkg/meta/base.go:1734` (`BatchClone` wrapper)

## Redis Key Patterns Used in Clone

- Inode attr key: `i{ino}` via `inodeKey`.
- Directory entry hash: `d{parent}` via `entryKey`.
- Chunk list key: `c{ino}_{idx}` via `chunkKey`.
- Symlink target key: `s{ino}` via `symKey`.
- Xattr hash key: `x{ino}` via `xattrKey`.
- Slice ref hash key: `sliceRef` (prefix-aware) via `sliceRefs`; field format `k{sliceId}_{size}` via `sliceKey`.
- Space/inode counters: `usedSpace`, `totalInodes` (prefix-aware).

Key builders:

- `pkg/meta/redis.go:620`
- `pkg/meta/redis.go:639`
- `pkg/meta/redis.go:759`

## Phase-1 Audit Notes (Per-Entry Redis Path)

Per-entry backend clone function:

- `pkg/meta/redis.go:4934` (`doCloneEntry`)

### Single file clone (1 chunk) command sequence (common recursive child case, `top=false`)

1. `WATCH i{srcIno} x{srcIno}` (transaction start by `m.txn`)  
2. `GET i{srcIno}` (read source attr)
3. `HGETALL x{srcIno}` (read source xattrs)
4. `LRANGE c{srcIno}_0 0 -1` (read chunk list for index 0)
5. `MULTI`
6. `SET i{dstIno} ...`
7. `INCRBY usedSpace align4K(length)`
8. `INCR totalInodes`
9. `HSET d{dstParent} {name} packEntry(...)`
10. `RPUSH c{dstIno}_0 ...`
11. `HINCRBY sliceRef k{sliceId}_{size} 1` (per slice)
12. `EXEC`
13. `UNWATCH`

Notes:

- If xattrs exist, `HMSET x{dstIno} ...` is added inside transaction.
- If a chunk contains multiple slices, step 11 repeats for each slice.

### Single file clone (`top=true`) additional checks/updates

Adds read checks before write transaction and parent timestamp write inside transaction:

- `GET i{dstParent}`
- `HEXISTS d{dstParent} {name}`
- `SET i{dstParent} ...` (mtime/ctime update) inside `MULTI`.

### Single symlink clone command sequence (`top=false`)

1. `WATCH i{srcIno} x{srcIno}`
2. `GET i{srcIno}`
3. `HGETALL x{srcIno}`
4. `GET s{srcIno}`
5. `MULTI`
6. `SET i{dstIno} ...`
7. `INCRBY usedSpace ...`
8. `INCR totalInodes`
9. `HSET d{dstParent} {name} ...`
10. `SET s{dstIno} {target}`
11. `EXEC`
12. `UNWATCH`

### Chunk reference counting correctness

- Reference tracking is in hash `sliceRef` with field `k{sliceId}_{size}`.
- Per-entry path increments refs with `HINCRBY ... +1` for every copied slice occurrence.
- Batch path aggregates by field and applies one increment per field per sub-batch.

References:

- `pkg/meta/redis.go:5043` (per-entry increments)
- `pkg/meta/redis.go:5289` and `pkg/meta/redis.go:5327` (batch aggregation + apply)

### Hardlinks

- Hardlinks are not preserved as links in clone.
- Current behavior resets file `Nlink` to `1` when source has `Nlink > 1`.
- Explicit TODO exists in per-entry path.

References:

- `pkg/meta/redis.go:4959`
- `pkg/meta/redis.go:5265`

### Xattrs

- Source xattrs: `HGETALL x{srcIno}`.
- Destination xattrs: `HMSET x{dstIno} ...` only when non-empty.

References:

- `pkg/meta/redis.go:4962`
- `pkg/meta/redis.go:5302`

### ACL / access checks

- Access checks are performed in base + backend clone paths.
- If ACL is set (`AccessACL != None`) and mode requires it, `doGetFacl` fetches ACL rule from hash key `acl` (`HGET acl {id}`) unless cached.
- So clone may issue additional ACL Redis reads conditionally.

References:

- `pkg/meta/base.go:1282` (`Access`)
- `pkg/meta/redis.go:5525` (`doGetFacl`)
- `pkg/meta/redis.go:5549` (`getACL`)

### Lua in clone path

- No Lua script is used by `doCloneEntry` or `doBatchClone`.
- Lua is used by `doLookup` (`scriptLookup`) and `Resolve` (`scriptResolve`) only.

References:

- `pkg/meta/redis.go:979`, `pkg/meta/redis.go:1030`
- `pkg/meta/lua_scripts.go:20`, `pkg/meta/lua_scripts.go:33`

## Existing Redis Batching Patterns Inventory

Collected inventory in `pkg/meta/redis.go`:

- Pipeline/TxPipeline usage points: 42
- Eval/EvalSha usage points: 2

Raw inventories generated during audit:

- `/tmp/redis_pipeline_inventory.txt`
- `/tmp/redis_pipeline_inventory_with_func.txt`
- `/tmp/redis_eval_inventory.txt`

Notable multi-entry batch functions already present before this work:

- `doBatchUnlink` (batched delete/unlink) at `pkg/meta/redis.go:1727`
- `doUpdateDirStat` (grouped pipelined stat updates, batch 1000) at `pkg/meta/redis.go:3130`

`doBatchClone` uses same style:

- read pipeline inside transaction (`tx.Pipeline`) for source xattrs/chunks/symlink data
- transactional write pipeline (`tx.TxPipelined`) for destination state and counters

## SQL Batch Clone Review (Companion)

Main function:

- `pkg/meta/sql.go:5076` (`doBatchClone`)

Interface contract and caller:

- `pkg/meta/base.go:1734` (`BatchClone` wrapper)
- `pkg/meta/base.go:3347` (fallback contract when `ENOTSUP`)
- `pkg/meta/interface.go:500` (`Clone` with `concurrency`)

What SQL version does (high-level):

- Pre-allocates destination inodes.
- Batch-fetches source nodes/chunks/symlinks/xattrs.
- Builds in-memory clone buffers.
- Inserts nodes/edges/chunks/symlinks/xattrs in bulk.
- Aggregates chunk refs by chunk id and applies batched `CASE WHEN` updates.
- Updates parent timestamps.

Chunk-ref aggregation reference:

- `pkg/meta/sql.go:5269`
- `pkg/meta/sql.go:5385`

## Redis `doBatchClone` Design Implemented

Function:

- `pkg/meta/redis.go:5061`

Behavior:

1. Processes entries in bounded sub-batches (`batchSize = 1000`).
2. Pre-allocates destination inode IDs outside transaction.
3. Deduplicates source inode fetches per sub-batch.
4. In transaction: validates destination parent once and checks write/execute access once.
5. Reads source attrs via one `MGET`.
6. Reads source xattrs/chunks/symlink values via one read pipeline `Exec`.
7. Builds destination attrs in memory and computes totals + user/group quota deltas.
8. Aggregates `sliceRef` increments per `k{sliceId}_{size}` field.
9. Writes all destination state and counters in one `TxPipelined` block.
10. Returns `ENOTSUP` on unsupported/transient source conditions so caller can fallback.

Fallback triggers intentionally returning `ENOTSUP`:

- Source inode missing (`MGET` nil).
- Directory unexpectedly found in non-dir batch.
- Missing symlink payload.
- Unsupported type.

## Round-Trip Analysis (Current vs Old)

Assume N files, each with one chunk/slice, cloned as children in directory recursion.

Old per-entry path (`doCloneEntry`, `top=false`):

- Approx per file request/response exchanges: 6 to 7 (counting `WATCH`, 3 reads, transactional write exec, optional `UNWATCH`).
- For 1000 files: roughly 6000+ exchanges.
- Command mix per file (monitor-level): heavy `WATCH/MULTI/EXEC/UNWATCH` and per-file `GET/HGETALL/LRANGE`.

New batched path (`doBatchClone`, sub-batch=1000):

- Per 1000 files: roughly 5 to 6 exchanges total for clone core per sub-batch:
  - 1 `WATCH` call
  - 1 `GET` parent
  - 1 `MGET` source attrs
  - 1 read pipeline `Exec`
  - 1 write `TxPipelined` exec
  - optional `UNWATCH`
- Still O(N) commands for data copy (`HSET`, `RPUSH`, `LRANGE`, etc.), but control/transaction overhead collapses.

Reads vs writes (old path, 1-chunk/file approximation, excluding ACL extras):

- Reads: `GET + HGETALL + LRANGE` about 3 commands/file.
- Writes: `SET + INCRBY + INCR + HSET + RPUSH + HINCRBY` about 6 commands/file.
- Control: `WATCH + MULTI + EXEC + UNWATCH` about 4 commands/file.

## Load Test Methodology and Artifacts

Runner:

- `scripts/bench/redis_clone_compare.sh`

What it does:

- Ensures Redis container (`redis:7-alpine`) is running.
- Creates/uses baseline worktree at `/tmp/juicefs-baseline` pinned to `47e6338a`.
- Generates temporary clone harness (`.tmp_clonebench/main.go`) in each tree.
- Executes baseline/current clone runs for configured loads (`5000`, `10000`).
- Captures Redis `MONITOR` logs around clone start/end markers.
- Parses command counts and writes report.

Final report and raw artifacts:

- Report: `docs/redis-clone-loadtest.md`
- Artifact directory: `/tmp/redis_clone_compare_20260221_135446`

## Load Test Results (Old vs New)

Source of truth:

- `docs/redis-clone-loadtest.md:12`
- `docs/redis-clone-loadtest.md:19`

Summary table:

| Load | Version | Clone ms | Redis cmd delta (INFO) | MONITOR command lines |
|---:|---|---:|---:|---:|
| 5000 | baseline | 8807 | 65063 | 65060 |
| 5000 | current | 456 | 30100 | 29645 |
| 10000 | baseline | 16808 | 130070 | 130067 |
| 10000 | current | 1078 | 60158 | 60155 |

Derived:

- 5000 files: `19.31x` faster, `94.8%` lower time, `53.7%` fewer Redis commands.
- 10000 files: `15.59x` faster, `93.6%` lower time, `53.7%` fewer Redis commands.

Command-level evidence (selected):

- 5000 files: `WATCH 5002 -> 7`, `MULTI 5002 -> 7`, `EXEC 5002 -> 6`, `GET 5008 -> 14`, `INCRBY 5006 -> 22`.
- 10000 files: `WATCH 10002 -> 14`, `MULTI 10002 -> 14`, `EXEC 10002 -> 14`, `GET 10008 -> 21`, `INCRBY 10011 -> 42`.

## Validation / Test Logs

Redis metadata test report:

- `docs/redis-test-report.md`

Raw test log:

- `/tmp/juicefs_redis_test_20260221_134119.log`

Recorded test outcomes in this work session:

- `go test -v -run TestRedisClient -timeout 10m ./pkg/meta -count=1` passed.
- `go test -v -run TestSQLiteClient -timeout 10m ./pkg/meta -count=1` passed.
- `go vet ./pkg/meta/...` passed.
- `go test ./... -run TestDoesNotExist -count=1` used as compile sanity and passed.
- `golangci-lint` was not available on this machine.

## Progress Timeline (Condensed)

1. Applied baseline batch-clone plumbing patch set from PR companion context.
2. Implemented Redis `doBatchClone` with bounded batching, pipelined reads/writes, and slice-ref aggregation.
3. Ran Redis tests once Docker became available.
4. Built benchmark harness and compare script for baseline vs current.
5. Hit harness bug (`reflect: Call with too few input arguments`) due Clone arity mismatch.
6. Fixed harness arity handling (`arity=9` old signature, `arity=10` current signature).
7. Re-ran full 5k/10k comparison and captured report + raw logs.

## Troubleshooting Notes Preserved

- Initial benchmark rerun failed due stale worktree registration:
  - Error: `fatal: '/tmp/juicefs-baseline' is a missing but already registered worktree`
  - Fix used: `git worktree prune`, then rerun benchmark script.
- Initial harness run against current tree failed:
  - Panic: `reflect: Call with too few input arguments`
  - Root cause: harness only appended `concurrency` when arity was `11`; actual new `Clone` arity is `10`.
  - Fix: accept both signatures (`9` without concurrency, `10` with concurrency) in harness.
- Transient Redis warning observed during runs:
  - `maintnotifications disabled due to handshake error: ERR unknown subcommand 'maint_notifications'`
  - This warning did not block tests or benchmark execution.

## Important Risk Notes

- Batch clone intentionally returns `ENOTSUP` on uncertain source state to preserve correctness via safe fallback.
- This design prioritizes correctness over forcing batch success in edge conditions.
- Hardlink preservation remains intentionally unchanged from existing behavior (`Nlink` reset to `1` for cloned files).
- ACL checks can add conditional Redis reads depending on ACL mode/cache state.

## Deep-Dive Correctness Checks

### Thesis Used For Deep Checks

- H1: `sliceRef` updates in batch clone are aggregated correctly across entries in the same sub-batch.
- H2: Symlink entries are cloned correctly in batch mode with exact target preservation.
- H3: Hardlink semantics in batch mode match old per-entry behavior.
- H4: Used space and inode accounting after batch clone is exact.
- H5: Failure paths do not silently claim fallback if they are true hard errors; cleanup behavior is explicit and understood.

### Check 2: Symlink Handling

Code path verification:

- Batch read path for symlink targets:
  - `pkg/meta/redis.go:5199` queues `GET s{srcIno}` in `readPipe`.
  - `pkg/meta/redis.go:5229` reads pipeline result.
  - `pkg/meta/redis.go:5231` returns `ENOTSUP` if symlink target is missing (`redis.Nil`).
- Batch write path for symlinks:
  - `pkg/meta/redis.go:5313`
  - `pkg/meta/redis.go:5314` writes `SET s{dstIno} {target}`.

Behavior if symlink is invalid/missing in batch:

- `doBatchClone` returns `ENOTSUP` for missing symlink payload (`pkg/meta/redis.go:5231`).
- Caller `cloneEntry` falls back to per-entry cloning only on `ENOTSUP` (`pkg/meta/base.go:3347`).
- Unsupported types also return `ENOTSUP` in batch (`pkg/meta/redis.go:5200`, `pkg/meta/redis.go:5316`).

Test added:

- `pkg/meta/redis_batchclone_test.go:142`
- `TestRedisBatchCloneMixedFilesAndSymlinks`
- Scenario: 3 files + 2 symlinks in same batch clone.
- Verification: cloned symlink entries are type `TypeSymlink`; `ReadLink` target equals original target text.

Run:

```bash
go test -v -run TestRedisBatchCloneMixedFilesAndSymlinks -timeout 10m ./pkg/meta -count=1
```

Observed output:

- `--- PASS: TestRedisBatchCloneMixedFilesAndSymlinks (0.07s)`

### Check 3: Hardlink Behavior

Old per-entry behavior:

- `baseMeta.cloneEntry` allocates fresh destination inode per entry: `pkg/meta/base.go:3250`.
- Redis `doCloneEntry` explicitly resets hardlink count:
  - `pkg/meta/redis.go:4958` TODO comment
  - `pkg/meta/redis.go:4960` sets `Nlink = 1` when source `Nlink > 1`.

New batch behavior:

- `doBatchClone` allocates fresh destination inode per entry: `pkg/meta/redis.go:5108`.
- `srcSet/srcList` deduplicates only source reads, not output inode identity: `pkg/meta/redis.go:5119`.
- Batch path also resets hardlink count:
  - `pkg/meta/redis.go:5265`
  - `pkg/meta/redis.go:5266`.

What clone produces for `file_A` and `file_B` hardlinked to same source inode:

- Two independent destination files (two different destination inodes), both with `nlink = 1`.
- Not preserved as hardlinks.

SQL parity note:

- SQL old and batch paths also reset hardlinks:
  - `pkg/meta/sql.go:4968`
  - `pkg/meta/sql.go:5205`.

Test added:

- `pkg/meta/redis_batchclone_test.go:39`
- `TestRedisBatchCloneSharedChunkRefs`
- Also validates hardlink outcome:
  - destination inodes differ (`pkg/meta/redis_batchclone_test.go:126`)
  - both `nlink == 1` (`pkg/meta/redis_batchclone_test.go:132`)

Run:

```bash
go test -v -run TestRedisBatchCloneSharedChunkRefs -timeout 10m ./pkg/meta -count=1
```

Observed output:

- `--- PASS: TestRedisBatchCloneSharedChunkRefs (0.06s)`

### Check 4: Error Handling and Partial Failure Cleanup

There is no Lua eval in `doBatchClone`; failures are from read/write pipeline and transaction wrapper.

Failure points and behavior:

- Inode pre-allocation failure: `pkg/meta/redis.go:5109`.
- Destination parent read/permission/type checks: `pkg/meta/redis.go:5136`, `pkg/meta/redis.go:5142`, `pkg/meta/redis.go:5147`.
- Source fetch/validation: `pkg/meta/redis.go:5155`, `pkg/meta/redis.go:5163`, `pkg/meta/redis.go:5168`.
- Read pipeline execution and decode: `pkg/meta/redis.go:5204`, `pkg/meta/redis.go:5210`, `pkg/meta/redis.go:5217`, `pkg/meta/redis.go:5224`, `pkg/meta/redis.go:5231`.
- Write transaction execution: `pkg/meta/redis.go:5297`.

Fallback vs hard error:

- Only `ENOTSUP` leads to fallback in caller:
  - `pkg/meta/redis.go:5336`
  - `pkg/meta/base.go:3347`.
- Unexpected failures are hard errors (`errno(err)`), usually surfacing as `EIO`:
  - `pkg/meta/redis.go:5339`
  - `pkg/meta/utils.go:138`.

Atomicity/partial success reality:

- `TxPipelined` wraps `MULTI/EXEC` (`go-redis` `tx.go:126`, `tx.go:134`).
- It returns first failed command error (`go-redis` `tx.go:123`, `redis.go:764`).
- `doBatchClone` command order places inode/edge/chunk writes before `sliceRef` updates:
  - `pkg/meta/redis.go:5300` then `pkg/meta/redis.go:5301` then `pkg/meta/redis.go:5311` then counters and refs at `pkg/meta/redis.go:5320`, `pkg/meta/redis.go:5323`, `pkg/meta/redis.go:5327`.
- Therefore runtime command errors can leave partial state from earlier commands in the same transaction response set.

Cleanup behavior:

- `doBatchClone` has no internal rollback/cleanup block.
- `BatchClone` wrapper updates local stats/quota only on success (`pkg/meta/base.go:1743`), but does not cleanup Redis objects on failure.
- Top-level directory clone has detached-tree cleanup on overall clone failure:
  - `pkg/meta/base.go:3234`.
- That cleanup helps only if created nodes are reachable under detached root; unreachable/orphan partial keys remain a risk in specific failure shapes.

Fault-injection validation performed:

- Script used: `/tmp/redis_batchclone_partial_check.go`.
- Method: poison destination `d{dstParent}` key to string so `HSET` in batch write gets `WRONGTYPE`.
- Result:
  - `batchclone_status=input/output error`
  - `used_delta=4096`
  - `inodes_delta=1`
- Interpretation: hard error returned (no ENOTSUP fallback), and partial state/counter updates occurred.

### Check 8: Space Accounting

Where accounting is computed and applied:

- Per-entry accumulation:
  - `batchLength += int64(sd.attr.Length)` at `pkg/meta/redis.go:5270`
  - `batchSpace += align4K(sd.attr.Length)` at `pkg/meta/redis.go:5271`, `pkg/meta/redis.go:5272`
  - `batchInodes++` at `pkg/meta/redis.go:5273`.
- Redis counter updates in write transaction:
  - `IncrBy usedSpace` at `pkg/meta/redis.go:5320`
  - `IncrBy totalInodes` at `pkg/meta/redis.go:5323`.
- In-memory stat cache update on success:
  - `m.en.updateStats(space, inodes)` at `pkg/meta/base.go:1744`.

Test added:

- `pkg/meta/redis_batchclone_test.go:245`
- `TestRedisBatchCloneSpaceAccounting`
- Scenario:
  - source files of 4096, 8192, 12288 bytes.
  - batch clone to destination.
  - compare `StatFS` used-space and inode deltas before/after.
  - expected used delta uses `align4K`.

Run:

```bash
go test -v -run TestRedisBatchCloneSpaceAccounting -timeout 10m ./pkg/meta -count=1
```

Observed output:

- `space/inode delta verified: usedDelta=24576 inodeDelta=3`
- `--- PASS: TestRedisBatchCloneSpaceAccounting (0.06s)`

### Added Test Inventory (This Session)

- `pkg/meta/redis_batchclone_test.go:39` `TestRedisBatchCloneSharedChunkRefs`
- `pkg/meta/redis_batchclone_test.go:142` `TestRedisBatchCloneMixedFilesAndSymlinks`
- `pkg/meta/redis_batchclone_test.go:245` `TestRedisBatchCloneSpaceAccounting`
- `pkg/meta/redis_batchclone_test.go:343` `TestRedisBatchCloneMultiChunkFile`
- `pkg/meta/redis_batchclone_test.go:466` `TestRedisBatchClonePartialFailureLeavesState`

All tests above were run on local Redis; the partial-failure test intentionally validates leakage behavior under injected `WRONGTYPE` failure.

## Reproduction Commands

Redis tests:

```bash
docker run -d --rm --name jfs-redis-test -p 6379:6379 redis:7-alpine
go test -v -run TestRedisClient -timeout 10m ./pkg/meta -count=1
```

Old vs new clone load test:

```bash
bash scripts/bench/redis_clone_compare.sh
```

Optional custom loads:

```bash
LOADS="20000 40000" bash scripts/bench/redis_clone_compare.sh
```

## Local-Only Note

- This working document and generated logs can stay local.
- No push is required.

## Check 5: Test Coverage Audit (Latest)

Date of rerun: 2026-02-21

Full Redis suite command (requested):

```bash
go test -v -run TestRedisClient -timeout 10m ./pkg/meta -count=1
```

Latest full log:

- `/tmp/redis_full_suite_20260221_latest.log`

Latest result summary:

- `--- PASS: TestRedisClient (100.52s)`
- `PASS`
- `ok github.com/juicedata/juicefs/pkg/meta 101.461s`

### Clone-Related Tests Found

- `pkg/meta/base_test.go:2987` `testClone` (invoked from `TestRedisClient -> testMeta`)
- `pkg/meta/base_test.go:4147` subtest `CloneQuotaCheck`
- `pkg/meta/redis_batchclone_test.go:40` `TestRedisBatchCloneSharedChunkRefs`
- `pkg/meta/redis_batchclone_test.go:143` `TestRedisBatchCloneMixedFilesAndSymlinks`
- `pkg/meta/redis_batchclone_test.go:246` `TestRedisBatchCloneSpaceAccounting`
- `pkg/meta/redis_batchclone_test.go:343` `TestRedisBatchCloneMultiChunkFile` (added)
- `pkg/meta/redis_batchclone_test.go:466` `TestRedisBatchClonePartialFailureLeavesState` (added)

Targeted clone test run:

```bash
go test -v -run 'TestRedisBatchCloneSharedChunkRefs|TestRedisBatchCloneMixedFilesAndSymlinks|TestRedisBatchCloneSpaceAccounting|TestRedisBatchCloneMultiChunkFile|TestRedisBatchClonePartialFailureLeavesState' -timeout 10m ./pkg/meta -count=1
```

Targeted log:

- `/tmp/redis_clone_target_tests_20260221.log`

### Scenario Coverage Matrix

- Clone directory with only files: `✓`
  - Covered by `TestRedisBatchCloneSpaceAccounting`.
- Clone directory with files AND symlinks: `✓`
  - Covered by `TestRedisBatchCloneMixedFilesAndSymlinks`.
- Clone directory with empty files (zero chunks): `✓`
  - Covered by `TestRedisBatchCloneMixedFilesAndSymlinks` (files created, no writes).
- Clone directory with multi-chunk files: `✓` (added)
  - Covered by `TestRedisBatchCloneMultiChunkFile`.
- Clone directory with hardlinked files: `✓`
  - Covered by `TestRedisBatchCloneSharedChunkRefs` and `testClone`.
- Clone nested directories (batch handles non-dirs, dirs recurse): `✓`
  - Covered by `testClone`.
- Clone with quota enforcement: `✓`
  - Covered by subtest `CloneQuotaCheck`.
- Error during clone (partial failure recovery): `✓` (added)
  - Covered by `TestRedisBatchClonePartialFailureLeavesState`.

### New Test Findings

- `TestRedisBatchCloneMultiChunkFile`:
  - Confirms two chunk indexes are copied (`0` and `1`) and both slice refs are incremented once.
- `TestRedisBatchClonePartialFailureLeavesState`:
  - Fault injects `WRONGTYPE` on `sliceRef` so batch `HINCRBY` fails.
  - `BatchClone` returns hard error (`EIO`), not `ENOTSUP`.
  - Destination entry and stat deltas are still written (`usedDelta=4096`, `inodeDelta=1`), confirming partial-write leakage risk on this failure path.

### Known Limitations (Documented)

- WATCH scope in Redis batch clone is inode/xattr keys, not chunk list keys:
  - `pkg/meta/redis.go:5125` watches `i{srcIno}` / `x{srcIno}` and destination parent keys.
  - Chunk lists are read by pipelined `LRANGE c{ino}_{idx}` (`pkg/meta/redis.go:5194`).
- Implication:
  - Concurrent writes/truncate usually mutate inode attrs and are caught by WATCH retry.
  - Chunk-only maintenance mutations can still race and be cloned from a moving chunk view.
- This is not unique to batch clone; old per-entry `doCloneEntry` uses the same watch scope (`pkg/meta/redis.go:5058`).
