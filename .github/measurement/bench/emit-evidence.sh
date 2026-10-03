#!/usr/bin/env bash
# emit-evidence.sh: print everything in $EVIDENCE the collector reads, one
# `BENCH-EVIDENCE <kind> <compact-json>` line per record. The job log is the
# only evidence channel (no Actions artifacts), so one record must never span
# or share a line.
#   profile  the runner profile; versions: tool versions on PATH
#   phase    each row of phases.jsonl
#   result   each per-directory row of result*.jsonl (scalar fields only), plus
#            each test of a chainsaw JSON report (chainsaw-report*.json)
#   sidecar  each small JSON sidecar: {"file": name, "data": {...}}
set -uo pipefail
# profile: the runner as capture-runner measured it (vCPU accounting uses it).
[ -f "${RUNNER_TEMP:-}/runner-profile.json" ] && jq -c . "$RUNNER_TEMP/runner-profile.json" | sed 's/^/BENCH-EVIDENCE profile /'
# versions: whatever tools this job has on PATH.
v() { command -v "$1" >/dev/null 2>&1 && "$@" 2>/dev/null | head -1 | tr -d '"\\' ; }
printf 'BENCH-EVIDENCE versions {"chainsaw":"%s","helm":"%s","kubectl_client":"%s","kind":"%s"}\n' \
  "$(v chainsaw version)" "$(v helm version --short)" "$(v kubectl version --client)" "$(v kind version)"
cd "${EVIDENCE:?}" || exit 0
[ -f phases.jsonl ] && sed 's/^/BENCH-EVIDENCE phase /' phases.jsonl
for f in result*.jsonl; do
  [ -f "$f" ] || continue
  jq -c 'with_entries(select(.value|type!="object" and type!="array"))' "$f" | sed 's/^/BENCH-EVIDENCE result /'
done
# A chainsaw v0.2.15 JSON report has no per-test status: a skipped test
# carries `skipped`, a failed one a `failure` somewhere under its steps, and a
# pass neither (the rule run-shards.py uses). Its basePath is relative to the
# chainsaw working directory, so BENCH_TESTS_PATH (that directory relative to
# test/conformance/chainsaw) prefixes it to give the population's name.
for f in chainsaw-report*.json; do
  [ -f "$f" ] || continue
  jq -c --arg job "${BENCH_JOB:-}" --arg prefix "${BENCH_TESTS_PATH:-}" '.tests[]? | {
      dir: (.basePath | sub("^.*/test/conformance/chainsaw/"; "") | sub("^\\./"; "")
            | if ($prefix != "" and (startswith($prefix + "/") | not)) then $prefix + "/" + . else . end),
      bucket: (if .skipped then "not-run"
               elif ([.. | objects | select(has("failure") and .failure != null and .failure != "")] | length) > 0 then "fail"
               else "pass" end),
      start: .startTime, end: .endTime, job: $job}' "$f" | sed 's/^/BENCH-EVIDENCE result /'
done
for f in *.json; do
  [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 65536 ] || continue
  case "$f" in chainsaw-report*) continue ;; esac
  jq -c --arg f "$f" '{file: $f, data: .}' "$f" 2>/dev/null | sed 's/^/BENCH-EVIDENCE sidecar /'
done
# Diagnostics, not evidence: the tail of each tool log, so a step that failed
# with its stderr redirected to a file still says why in the job log.
for f in *.log; do
  [ -f "$f" ] || continue
  echo "::group::tail $f"; tail -n 40 "$f"; echo "::endgroup::"
done
exit 0
