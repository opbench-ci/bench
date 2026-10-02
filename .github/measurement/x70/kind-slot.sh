#!/usr/bin/env bash
# kind-slot.sh SLOT PLAN.tsv : run one slot of a kind-plan.py plan.
#
# For each installation group in the plan, in order: bring up one kind
# cluster with that group's Kyverno values and kind config (up.sh, CI-shaped,
# host ports dropped so two clusters can coexist), record the reset baseline
# and a residual-state inventory, then for each directory: one p82-kind-sweep
# chainsaw invocation of that directory alone with its suite's configuration
# (failFast off, no retry), followed by the bundle's sanitize.sh, which resets
# the shared cluster to its post-install state (test namespaces, cluster-scoped
# policies, test-authored webhooks and admission policies, update requests,
# reports, objects left in kept namespaces). Chainsaw's own per-test cleanup
# alone left cluster-scoped policies behind that failed later directories in
# the pilot (protocol, amendment P1). After the group's last directory: the
# residual diff, then the cluster is deleted. A group whose cluster fails to
# come up is not retried: its directories report no outcome.
# Needs BUNDLE, EVIDENCE, NODE_IMAGE, GITHUB_WORKSPACE, RUNNER_TEMP.
set -uo pipefail
slot=$1; plan=$2
M="$GITHUB_WORKSPACE/.github/measurement/x70"
P="$GITHUB_WORKSPACE/.github/measurement/bench/phase.sh"
rc=0
[ -s "$plan" ] || exit 0
for g in $(cut -f1 "$plan" | awk '!seen[$0]++'); do
  case "$g" in
    B1-standard) configs=standard; kc_file=./scripts/config/kind/default.yaml ;;
    B2-default) configs=default; kc_file=./scripts/config/kind/default.yaml ;;
    B3-force-failure-policy-ignore) configs=standard,force-failure-policy-ignore; kc_file=./scripts/config/kind/default.yaml ;;
    B4-generate-map) configs=standard,generate-mutating-admission-policy; kc_file=./scripts/config/kind/vap-v1beta1.yaml ;;
    B5-map-reports) configs=standard,mutating-admission-policy-reports; kc_file=./scripts/config/kind/vap-v1beta1.yaml ;;
    *) echo "unknown group $g" >&2; rc=1; continue ;;
  esac
  cl="s$slot-$(echo "$g" | cut -d- -f1 | tr 'A-Z' 'a-z')"
  kcfg="$RUNNER_TEMP/kubeconfig-$cl"
  tag="s$slot-$g"
  if ! CI_SHAPED=1 CONTROLLERS=all KYVERNO_ROOT="$GITHUB_WORKSPACE/upstream" \
      P82_SUT_DIR="$BUNDLE/artifacts/sut/kyverno-admission" NODE_IMAGE="$NODE_IMAGE" \
      KYVERNO_CONFIGS="$configs" KIND_CONFIG="$kc_file" KIND_NO_HOST_PORTS=1 \
      INSTALL_KUBECTL_EVICT=0 INSTALL_OPENREPORTS=0 \
      "$P" "kind_up:$tag" bash -c '"$BUNDLE/hack/p82-kind/up.sh" "$0" "$1" > "$EVIDENCE/up-$2.json" 2> "$EVIDENCE/up-$2.log"' "$cl" "$kcfg" "$tag"; then
    echo "{\"slot\":$slot,\"group\":\"$g\",\"cluster_up\":false}" > "$EVIDENCE/slot-$tag.json"
    "$P" "kind_down:$tag" "$BUNDLE/hack/p82-kind/down.sh" "$cl" || true
    rc=1; continue
  fi
  KUBECONFIG="$kcfg" "$P" "sanitize_baseline:$tag" bash -c '
    kubectl api-resources --namespaced=true --verbs=list,delete -o name 2>/dev/null \
      | grep -Ev "^(events|events\.events\.k8s\.io)$" | paste -sd, - > "$KUBECONFIG.sanitize-types"
    for ns in default kube-system kube-public kube-node-lease kyverno local-path-storage; do
      kubectl -n "$ns" get "$(cat "$KUBECONFIG.sanitize-types")" -o name 2>/dev/null | sed "s|^|$ns |"
    done | LC_ALL=C sort > "$KUBECONFIG.sanitize-baseline"'
  "$M/residual.sh" snap "$kcfg" > "$RUNNER_TEMP/inventory-$tag.txt"
  n=0
  while IFS=$'\t' read -r -u 3 grp job dir; do
    [ "$grp" = "$g" ] || continue
    n=$((n + 1))
    printf '%s\n' "$dir" > "$RUNNER_TEMP/dir-$tag-$n.dirs"
    out="$RUNNER_TEMP/result-$tag-$n.jsonl"
    (cd "$BUNDLE" && "$P" "kind_test:$tag" \
      ./bin/p82-kind-sweep -kyverno "$GITHUB_WORKSPACE/upstream" -kubeconfig "$kcfg" \
        -controllers all -upstream-ci -no-fail-fast -ci-parallel 1 \
        -from docs/p82/kyverno-final-2026-09-18-c1-r1.jsonl -ci-manifest docs/p82/ci-shards-2026-09-19.json \
        -ci-shard "$job" -ci-dirs-file "$RUNNER_TEMP/dir-$tag-$n.dirs" -ci-setup-json "$EVIDENCE/up-$tag.json" \
        -out "$out" 2>> "$EVIDENCE/kind-sweep-s$slot.log") || rc=1
    [ -f "$out" ] && cat "$out" >> "$EVIDENCE/result-k-$tag.jsonl"
    KUBECONFIG="$kcfg" "$P" "sanitize:$tag" "$BUNDLE/hack/p82-kind/sanitize.sh" 2>> "$EVIDENCE/sanitize-s$slot.log" || true
  done 3< "$plan"
  "$P" "residual:$tag" bash -c '"$0" diff "$1" "$2" > "$EVIDENCE/residual-$3.json"' \
    "$M/residual.sh" "$kcfg" "$RUNNER_TEMP/inventory-$tag.txt" "$tag" || true
  echo "{\"slot\":$slot,\"group\":\"$g\",\"cluster_up\":true}" > "$EVIDENCE/slot-$tag.json"
  "$P" "kind_down:$tag" "$BUNDLE/hack/p82-kind/down.sh" "$cl" || true
done
exit $rc
