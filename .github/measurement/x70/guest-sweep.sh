#!/usr/bin/env bash
# guest-sweep.sh PLANDIR : run every <group>.dirs file in PLANDIR on guest
# clones, exactly as the earlier consolidated arm did: one cold baseline per
# installation group, then one isolated clone restored per directory, two at
# a time, one chainsaw process per directory, failFast off. The primary group
# runs first. Rows go to $EVIDENCE/result-g-<group>.jsonl.
# Needs BUNDLE, EVIDENCE, GITHUB_WORKSPACE and the HARNESS_* variables.
set -uo pipefail
plan=$1
P="$GITHUB_WORKSPACE/.github/measurement/bench/phase.sh"
cd "$BUNDLE" || exit 1
mkdir -p /tmp/gh-snapshots /tmp/gh
ln -sf "$BUNDLE/artifacts/vmlinux" "$BUNDLE/artifacts/initramfs.cpio.gz" /tmp/gh/  # the bundle ships its own guest
export HARNESS_ASSET_CACHE="$BUNDLE/cache/assets" HARNESS_FIRECRACKER="$BUNDLE/bin/firecracker" PATH="$BUNDLE/bin:$PATH"
export HARNESS_GUEST_BUILD_FINGERPRINT="$(cat guest-build-fingerprint)"
declare -A CONFIGS=(
  [B1-standard]=standard
  [B2-default]=default
  [B3-force-failure-policy-ignore]=standard,force-failure-policy-ignore
  [B4-generate-map]=standard,generate-mutating-admission-policy
  [B5-map-reports]=standard,mutating-admission-policy-reports
)
rc=0
for f in $(ls "$plan"/B1-standard.dirs 2>/dev/null) $(ls "$plan"/*.dirs 2>/dev/null | grep -v '/B1-standard.dirs$'); do
  [ -s "$f" ] || continue
  baseline=$(basename "$f" .dirs)
  export HARNESS_TIMING_JSONL="$EVIDENCE/harness-$baseline.jsonl"
  "$P" "sweep:$baseline" \
    ./bin/p82-sweep -kyverno "$GITHUB_WORKSPACE/upstream" -sut "$BUNDLE/artifacts/sut/kyverno-admission" \
    -install-ns kyverno -controllers all -upstream-ci -no-fail-fast -upstream-configs "${CONFIGS[$baseline]}" \
    -concurrency 2 -dirs-file "$f" -out "$EVIDENCE/result-g-$baseline.jsonl" 2> "$EVIDENCE/sweep-$baseline.log" || rc=1
done
exit $rc
