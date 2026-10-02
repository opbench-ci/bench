#!/usr/bin/env bash
# phase.sh NAME CMD... : run CMD, append one wall-clock record to
# $EVIDENCE/phases.jsonl, and exit with CMD's status. Every measured span of the
# every explicitly timed span in these workflows goes through here, so a step that combines operations still
# yields one explicit timestamp pair per operation.
set -uo pipefail
name=$1; shift
start=$(date +%s%N)
"$@"; rc=$?
end=$(date +%s%N)
printf '{"phase":"%s","start_unix_ns":%s,"end_unix_ns":%s,"wall_ms":%s,"exit":%s,"job":"%s","run_id":"%s","run_attempt":"%s"}\n' \
  "$name" "$start" "$end" $(( (end - start) / 1000000 )) "$rc" "${BENCH_JOB:-$GITHUB_JOB}" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" \
  | tee -a "$EVIDENCE/phases.jsonl"
exit $rc
