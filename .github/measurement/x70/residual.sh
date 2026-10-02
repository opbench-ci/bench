#!/usr/bin/env bash
# residual.sh snap KUBECONFIG > inventory.txt
# residual.sh diff KUBECONFIG inventory.txt > residual.json
# Bounded residual-state probe for a persistent kind cluster: the names of
# every namespace and every object of the policy, admission, CRD and RBAC
# API groups, taken right after bring-up (snap) and again after the cluster's
# last directory (diff). The diff counts what the directories left behind
# despite chainsaw's per-test cleanup. Policy reports and events are excluded:
# Kyverno and the API server create and expire them on their own.
set -uo pipefail
mode=$1; export KUBECONFIG=$2
inventory() {
  # A namespace chainsaw already asked to delete is still Terminating when
  # the last test ends; it is listed as namespace-terminating/<name>, so the
  # diff separates "cleanup still running" from "left behind".
  kubectl get namespaces -o jsonpath='{range .items[*]}{.status.phase} {.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '$1 == "Terminating" {print "namespace-terminating/" $2; next} {print "namespace/" $2}'
  types=$(kubectl api-resources --verbs=list -o name 2>/dev/null \
    | grep -E '\.(kyverno\.io|admissionregistration\.k8s\.io|apiextensions\.k8s\.io|rbac\.authorization\.k8s\.io)$' \
    | grep -vE 'report' | paste -sd, -)
  [ -n "$types" ] && kubectl get "$types" -A -o name 2>/dev/null
}
case "$mode" in
  snap) inventory | LC_ALL=C sort -u ;;
  diff)
    now=$(mktemp); inventory | LC_ALL=C sort -u > "$now"
    added=$(LC_ALL=C comm -13 "$3" "$now"); removed=$(LC_ALL=C comm -23 "$3" "$now")
    jq -n --arg a "$added" --arg r "$removed" '
      ($a | split("\n") | map(select(. != ""))) as $add |
      ($r | split("\n") | map(select(. != ""))) as $rem |
      {added: ($add | length), removed: ($rem | length),
       added_by_kind: ($add | map(split("/")[0]) | group_by(.) | map({key: .[0], value: length}) | from_entries),
       added_sample: $add[:25], removed_sample: $rem[:10]}'
    rm -f "$now" ;;
  *) echo "usage: residual.sh snap|diff KUBECONFIG [inventory]" >&2; exit 2 ;;
esac
