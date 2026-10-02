#!/usr/bin/env bash
# emit-evidence.sh: print everything in $EVIDENCE the collector reads, one
# `BENCH-EVIDENCE <kind> <compact-json>` line per record (the job log is the
# only evidence channel). Same record kinds as ../bench/emit-evidence.sh;
# a result row additionally carries `src`, the file it came from, so a
# directory run twice in one job (substrate attempt, then kind) keeps both rows:
#   result-g-*.jsonl  substrate (guest clone) rows
#   result-k-*.jsonl  kind rows
set -uo pipefail
[ -f "${RUNNER_TEMP:-}/runner-profile.json" ] && jq -c . "$RUNNER_TEMP/runner-profile.json" | sed 's/^/BENCH-EVIDENCE profile /'
v() { command -v "$1" >/dev/null 2>&1 && "$@" 2>/dev/null | head -1 | tr -d '"\\' ; }
printf 'BENCH-EVIDENCE versions {"chainsaw":"%s","helm":"%s","kubectl_client":"%s","kind":"%s"}\n' \
  "$(v chainsaw version)" "$(v helm version --short)" "$(v kubectl version --client)" "$(v kind version)"
cd "${EVIDENCE:?}" || exit 0
# Resource fit: lowest free+cache memory and highest run queue vmstat saw.
if [ -f vmstat.txt ]; then
  awk 'NR>2 && $1 ~ /^[0-9]+$/ {r=$1; fr=$4+$6; if (min==""||fr<min) min=fr; if (r>maxr) maxr=r; si+=$7; so+=$8; n++}
       END {printf "{\"samples\":%d,\"min_free_plus_cache_kib\":%d,\"max_runq\":%d,\"swap_in_sum\":%d,\"swap_out_sum\":%d}\n", n, min, maxr, si, so}' \
    vmstat.txt > vmstat-summary.json 2>/dev/null || true
fi
[ -f phases.jsonl ] && sed 's/^/BENCH-EVIDENCE phase /' phases.jsonl
for f in result*.jsonl; do
  [ -f "$f" ] || continue
  jq -c --arg src "$f" 'with_entries(select(.value|type!="object" and type!="array")) + {src: $src}' "$f" | sed 's/^/BENCH-EVIDENCE result /'
done
for f in *.json; do
  [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 65536 ] || continue
  jq -c --arg f "$f" '{file: $f, data: .}' "$f" 2>/dev/null | sed 's/^/BENCH-EVIDENCE sidecar /'
done
for f in *.log; do
  [ -f "$f" ] || continue
  case "$f" in *.chainsaw.log) continue ;; esac
  echo "::group::tail $f"; tail -n 40 "$f"; echo "::endgroup::"
done
exit 0
