#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE_WORKTREE="${BASELINE_WORKTREE:-/tmp/juicefs-baseline}"
BASELINE_REF="${BASELINE_REF:-47e6338a}"
REDIS_CONTAINER="${REDIS_CONTAINER:-jfs-redis-test}"
REDIS_PORT="${REDIS_PORT:-6379}"
LOADS="${LOADS:-5000 10000}"
REPORT_PATH="${REPORT_PATH:-$ROOT_DIR/docs/redis-clone-loadtest.md}"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
TMP_DIR="/tmp/redis_clone_compare_${RUN_TS}"

mkdir -p "$TMP_DIR"

ensure_redis() {
  if ! docker ps --format '{{.Names}}' | rg -x "$REDIS_CONTAINER" >/dev/null 2>&1; then
    docker run -d --rm --name "$REDIS_CONTAINER" -p "${REDIS_PORT}:6379" redis:7-alpine >/dev/null
    sleep 2
  fi
}

ensure_baseline_worktree() {
  if [[ ! -d "$BASELINE_WORKTREE/.git" ]]; then
    git -C "$ROOT_DIR" worktree add --detach "$BASELINE_WORKTREE" "$BASELINE_REF"
  fi
}

write_harness() {
  local repo="$1"
  mkdir -p "$repo/.tmp_clonebench"
  cat > "$repo/.tmp_clonebench/main.go" <<'GOEOF'
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/juicedata/juicefs/pkg/meta"
)

func parseInfoInt64(info, key string) int64 {
	prefix := key + ":"
	for _, line := range strings.Split(info, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			v, _ := strconv.ParseInt(strings.TrimPrefix(line, prefix), 10, 64)
			return v
		}
	}
	return 0
}

func getStats(ctx context.Context, rdb *redis.Client) (int64, int64, int64) {
	info, err := rdb.Info(ctx, "stats").Result()
	if err != nil {
		log.Fatalf("failed to get redis stats: %v", err)
	}
	cmds := parseInfoInt64(info, "total_commands_processed")
	inBytes := parseInfoInt64(info, "total_net_input_bytes")
	outBytes := parseInfoInt64(info, "total_net_output_bytes")
	return cmds, inBytes, outBytes
}

func must(st syscall.Errno, what string) {
	if st != 0 {
		log.Fatalf("%s failed: %s", what, st)
	}
}

func main() {
	var redisAddr string
	var db int
	var files int
	var concurrency int
	var runID string
	flag.StringVar(&redisAddr, "redis-addr", "127.0.0.1:6379", "redis address")
	flag.IntVar(&db, "db", 10, "redis db")
	flag.IntVar(&files, "files", 5000, "number of files")
	flag.IntVar(&concurrency, "concurrency", 4, "clone concurrency")
	flag.StringVar(&runID, "run-id", "", "unique run id")
	flag.Parse()
	if runID == "" {
		runID = strconv.FormatInt(time.Now().UnixNano(), 10)
	}

	conf := meta.DefaultConf()
	conf.DirStatFlushPeriod = 100 * time.Millisecond

	uri := fmt.Sprintf("redis://%s/%d", redisAddr, db)
	m := meta.NewClient(uri, conf)
	defer func() { _ = m.Shutdown() }()

	if err := m.Reset(); err != nil {
		log.Fatalf("reset meta failed: %v", err)
	}
	if err := m.Init(&meta.Format{Name: "clone-bench", DirStats: true}, true); err != nil {
		log.Fatalf("init meta failed: %v", err)
	}

	ctx := meta.Background()
	var srcIno meta.Ino
	must(m.Mkdir(ctx, meta.RootInode, "src", 0777, 0, 0, &srcIno, nil), "mkdir src")

	for i := 0; i < files; i++ {
		var ino meta.Ino
		name := fmt.Sprintf("f%06d", i)
		must(m.Mknod(ctx, srcIno, name, meta.TypeFile, 0644, 022, 0, "", &ino, nil), "mknod")
		var sid uint64
		must(m.NewSlice(ctx, &sid), "new slice")
		must(m.Write(ctx, ino, 0, 0, meta.Slice{Id: sid, Size: 4096, Off: 0, Len: 4096}, time.Now()), "write")
	}

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr, DB: db})
	defer func() { _ = rdb.Close() }()

	cmdBefore, inBefore, outBefore := getStats(context.Background(), rdb)
	startMarker := "CLONE_START_" + runID
	endMarker := "CLONE_END_" + runID
	if err := rdb.Do(context.Background(), "ECHO", startMarker).Err(); err != nil {
		log.Fatalf("failed to emit start marker: %v", err)
	}

	var count, total uint64
	cloneMethod := reflect.ValueOf(m).MethodByName("Clone")
	if !cloneMethod.IsValid() {
		log.Fatalf("Clone method not found")
	}
	arity := cloneMethod.Type().NumIn()
	args := []reflect.Value{
		reflect.ValueOf(ctx),
		reflect.ValueOf(meta.RootInode), // src parent
		reflect.ValueOf(srcIno),         // src inode
		reflect.ValueOf(meta.RootInode), // dst parent
		reflect.ValueOf("dst"),
		reflect.ValueOf(uint8(0)),       // cmode
		reflect.ValueOf(uint16(022)),    // cumask
	}
	switch arity {
	case 10:
		args = append(args, reflect.ValueOf(uint8(concurrency)))
	case 9:
		// Old signature without explicit concurrency argument.
	default:
		log.Fatalf("unexpected Clone arity: %d", arity)
	}
	args = append(args, reflect.ValueOf(&count), reflect.ValueOf(&total))

	t0 := time.Now()
	res := cloneMethod.Call(args)
	cloneElapsed := time.Since(t0)
	eno, ok := res[0].Interface().(syscall.Errno)
	if !ok {
		log.Fatalf("unexpected clone return type: %T", res[0].Interface())
	}

	if err := rdb.Do(context.Background(), "ECHO", endMarker).Err(); err != nil {
		log.Fatalf("failed to emit end marker: %v", err)
	}
	cmdAfter, inAfter, outAfter := getStats(context.Background(), rdb)
	if eno != 0 {
		log.Fatalf("clone failed: %s", eno)
	}

	fmt.Printf(
		"RESULT run_id=%s arity=%d files=%d clone_ms=%d count=%d total=%d cmd_before=%d cmd_after=%d cmd_delta=%d net_in_delta=%d net_out_delta=%d start_marker=%s end_marker=%s\n",
		runID, arity, files, cloneElapsed.Milliseconds(), count, total,
		cmdBefore, cmdAfter, cmdAfter-cmdBefore, inAfter-inBefore, outAfter-outBefore,
		startMarker, endMarker,
	)
}
GOEOF
}

extract_result_field() {
  local line="$1"
  local key="$2"
  awk -v k="$key" '{
    for (i = 1; i <= NF; i++) {
      split($i, a, "=")
      if (a[1] == k) {
        print a[2]
        exit
      }
    }
  }' <<<"$line"
}

run_case() {
  local label="$1"
  local repo="$2"
  local db="$3"
  local files="$4"

  write_harness "$repo"

  local run_id="${label}_${files}_$(date +%s%N)"
  local monitor_log="$TMP_DIR/monitor_${label}_${files}.log"
  local run_log="$TMP_DIR/run_${label}_${files}.log"
  local monitor_pid

  docker exec "$REDIS_CONTAINER" redis-cli MONITOR >"$monitor_log" 2>&1 &
  monitor_pid=$!
  sleep 1

  set +e
  (
    cd "$repo"
    go run ./.tmp_clonebench \
      -redis-addr "127.0.0.1:${REDIS_PORT}" \
      -db "$db" \
      -files "$files" \
      -concurrency 4 \
      -run-id "$run_id"
  ) | tee "$run_log"
  local rc=${PIPESTATUS[0]}
  set -e

  kill "$monitor_pid" >/dev/null 2>&1 || true
  wait "$monitor_pid" 2>/dev/null || true

  if [[ $rc -ne 0 ]]; then
    echo "case failed: label=$label files=$files" >&2
    exit $rc
  fi

  local result_line
  result_line="$(rg '^RESULT ' "$run_log" | tail -n 1)"
  if [[ -z "$result_line" ]]; then
    echo "missing RESULT line for label=$label files=$files" >&2
    exit 1
  fi

  local start_marker end_marker
  start_marker="$(extract_result_field "$result_line" "start_marker")"
  end_marker="$(extract_result_field "$result_line" "end_marker")"

  local cmd_count_file="$TMP_DIR/cmd_counts_${label}_${files}.txt"
  awk -v s="$start_marker" -v e="$end_marker" '
    index($0, s) {on = 1; next}
    index($0, e) {on = 0; exit}
    on {
      if (match($0, /\"[^\"]+\"/)) {
        cmd = toupper(substr($0, RSTART + 1, RLENGTH - 2))
        cnt[cmd]++
        total++
      }
    }
    END {
      for (k in cnt) {
        print k, cnt[k]
      }
      print "__TOTAL__", total + 0
    }
  ' "$monitor_log" | sort >"$cmd_count_file"

  echo "$result_line" > "$TMP_DIR/result_${label}_${files}.txt"
}

build_report() {
  {
    echo "# Redis Clone Load Test Report"
    echo
    echo "- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Baseline worktree: \`$BASELINE_WORKTREE\` @ \`$BASELINE_REF\`"
    echo "- Current worktree: \`$ROOT_DIR\`"
    echo "- Redis container: \`$REDIS_CONTAINER\` on port \`$REDIS_PORT\`"
    echo "- Loads: \`$LOADS\` files (each file has 1 chunk/slice)"
    echo "- Raw artifacts: \`$TMP_DIR\`"
    echo
    echo "## Summary"
    echo
    echo "| Load | Version | Clone ms | Redis cmd delta (INFO) | MONITOR command lines |"
    echo "|---:|---|---:|---:|---:|"
    for files in $LOADS; do
      for label in baseline current; do
        local line cmd_delta clone_ms monitor_total
        line="$(cat "$TMP_DIR/result_${label}_${files}.txt")"
        cmd_delta="$(extract_result_field "$line" "cmd_delta")"
        clone_ms="$(extract_result_field "$line" "clone_ms")"
        monitor_total="$(awk '$1=="__TOTAL__"{print $2}' "$TMP_DIR/cmd_counts_${label}_${files}.txt")"
        echo "| $files | $label | $clone_ms | $cmd_delta | $monitor_total |"
      done
    done
    echo
    echo "## Top MONITOR Commands By Case"
    echo
    for files in $LOADS; do
      for label in baseline current; do
        echo "### ${label} / ${files} files"
        echo
        echo '```text'
        sort -k2 -nr "$TMP_DIR/cmd_counts_${label}_${files}.txt" | head -n 20
        echo '```'
        echo
      done
    done
  } > "$REPORT_PATH"
}

main() {
  ensure_redis
  ensure_baseline_worktree

  for files in $LOADS; do
    # Use separate DBs to avoid cross-run contamination.
    run_case "baseline" "$BASELINE_WORKTREE" 10 "$files"
    run_case "current" "$ROOT_DIR" 11 "$files"
  done

  build_report
  echo "report_path=$REPORT_PATH"
  echo "artifacts_dir=$TMP_DIR"
}

main "$@"
