# Redis Clone Load Test Report

- Date: 2026-02-21T21:59:13Z
- Baseline worktree: `/tmp/juicefs-baseline` @ `47e6338a`
- Current worktree: `/Users/vyalamar/Documents/juicefs`
- Redis container: `jfs-redis-test` on port `6379`
- Loads: `5000 10000` files (each file has 1 chunk/slice)
- Raw artifacts: `/tmp/redis_clone_compare_20260221_135446`

## Summary

| Load | Version | Clone ms | Redis cmd delta (INFO) | MONITOR command lines |
|---:|---|---:|---:|---:|
| 5000 | baseline | 8807 | 65063 | 65060 |
| 5000 | current | 456 | 30100 | 29645 |
| 10000 | baseline | 16808 | 130070 | 130067 |
| 10000 | current | 1078 | 60158 | 60155 |

## Derived Improvements

- 5000 files:
  - Time: `8807 ms -> 456 ms` (`19.31x` faster, `94.8%` lower latency)
  - Redis command delta: `65063 -> 30100` (`53.7%` reduction)
- 10000 files:
  - Time: `16808 ms -> 1078 ms` (`15.59x` faster, `93.6%` lower latency)
  - Redis command delta: `130070 -> 60158` (`53.7%` reduction)

## Command Reduction Signals

- 5000 files:
  - `WATCH`: `5002 -> 7`
  - `MULTI`: `5002 -> 7`
  - `EXEC`: `5002 -> 6`
  - `GET`: `5008 -> 14`
  - `INCRBY`: `5006 -> 22`
- 10000 files:
  - `WATCH`: `10002 -> 14`
  - `MULTI`: `10002 -> 14`
  - `EXEC`: `10002 -> 14`
  - `GET`: `10008 -> 21`
  - `INCRBY`: `10011 -> 42`

These reductions align with the batching design: far fewer per-entry transaction/control commands and far fewer metadata read-modify-write cycles.

## Reproduce

```bash
bash scripts/bench/redis_clone_compare.sh
```

## Top MONITOR Commands By Case

### baseline / 5000 files

```text
__TOTAL__ 65060
GET 5008
INCRBY 5006
HSET 5004
WATCH 5002
UNWATCH 5002
SET 5002
MULTI 5002
EXEC 5002
INCR 5001
HGETALL 5001
RPUSH 5000
LRANGE 5000
HINCRBY 5000
CLIENT 8
HGET 7
SELECT 4
HELLO 4
MGET 2
HEXISTS 2
```

### current / 5000 files

```text
__TOTAL__ 29645
HSET 5003
SET 5001
HGETALL 5001
RPUSH 5000
LRANGE 5000
HINCRBY 4559
INCRBY 22
GET 14
MGET 8
WATCH 7
MULTI 7
HGET 7
UNWATCH 6
EXEC 6
ZADD 1
INCR 1
HSCAN 1
HEXISTS 1
```

### baseline / 10000 files

```text
__TOTAL__ 130067
INCRBY 10011
GET 10008
HSET 10004
WATCH 10002
UNWATCH 10002
SET 10002
MULTI 10002
EXEC 10002
INCR 10001
HGETALL 10001
RPUSH 10000
LRANGE 10000
HINCRBY 10000
CLIENT 8
HGET 7
SELECT 4
HELLO 4
MGET 3
HSCAN 2
```

### current / 10000 files

```text
__TOTAL__ 60155
HSET 10004
SET 10002
HGETALL 10001
RPUSH 10000
LRANGE 10000
HINCRBY 10000
INCRBY 42
GET 21
MGET 15
WATCH 14
UNWATCH 14
MULTI 14
EXEC 14
HGET 7
HSCAN 2
HEXISTS 2
ZREM 1
ZADD 1
INCR 1
```
