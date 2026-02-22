# Redis Test Report

## Scope

This report documents the `TestRedisClient` run used to validate Redis metadata behavior after the `doBatchClone` work.

## Run Metadata

- Date (UTC): 2026-02-21
- Start time (UTC): 2026-02-21T21:41:19Z
- End time (UTC): 2026-02-21T21:43:49Z
- Host platform: `darwin/arm64`
- Go version: `go1.23.1`
- Docker version: `27.2.1-rd`
- Redis image: `redis:7-alpine`
- Redis container name: `jfs-redis-test`
- Redis container ID: `66e13254b999440e84cbcefbe610eaf752984880287131eb88bb00930d0eb5c5`
- Full raw log file: `/tmp/juicefs_redis_test_20260221_134119.log`

## Command Executed

```bash
docker run -d --rm --name jfs-redis-test -p 6379:6379 redis:7-alpine
go test -v -run TestRedisClient -timeout 10m ./pkg/meta -count=1
```

## Result

- Test exit code: `0`
- Package result: `ok github.com/juicedata/juicefs/pkg/meta 91.048s`
- Top-level test: `--- PASS: TestRedisClient (89.96s)`

### Subtests

- `TestRedisClient/BasicQuotaOperations` PASS
- `TestRedisClient/QuotaFileOperations` PASS
- `TestRedisClient/QuotaErrorCases` PASS
- `TestRedisClient/QuotaConcurrentOperations` PASS
- `TestRedisClient/QuotaMixedTypes` PASS
- `TestRedisClient/QuotaUsageStatistics` PASS
- `TestRedisClient/CheckQuotaFileOwner` PASS
- `TestRedisClient/QuotaEdgeCases` PASS
- `TestRedisClient/HardlinkQuota` PASS
- `TestRedisClient/BatchUnlinkWithUserGroupQuota` PASS

## Warning Summary

- Total `<WARNING>` lines: `113`
- Transaction retry warnings (`Transaction succeeded after ...`): `104`
- Leaked chunk warnings (`found leaked chunk ...`): `3`
- Check warnings for `/check` nlink state: `6`
- AOF warning (`AOF is not enabled ...`): `1`

## Notes

- The repeated transaction warnings indicate optimistic transaction retries that later succeeded.
- The run still completed with full PASS.
- The raw log is under `/tmp`; move it to a persistent location if long-term retention is needed.
