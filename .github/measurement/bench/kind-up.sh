#!/usr/bin/env bash
# P82 step 4 — bring up one kind cluster running the SAME Kyverno admission
# controller the VM harness `kyverno-admission` entry runs, so the conformance
# sweep can be re-scored against a control substrate.
#
# "Same" is meant literally where it can be:
#   * the SAME binaries — artifacts/sut/kyverno-admission/{kyverno,kyvernopre},
#     built from the pinned commit by `make -C examples/discovery/kyverno-admission
#     fetch-sut`, wrapped in a scratch image and side-loaded (never pulled);
#   * the SAME chart, at the same path, with the same three controllers
#     disabled and the same helm release name (`harness`);
#   * the SAME 22 seed CRDs, applied out-of-band with crds.install=false;
#   * the SAME boot-smoke ClusterPolicy the entry's baseline seeds, so both
#     substrates have a live ValidatingWebhookConfiguration before test one;
#   * the SAME Kubernetes minor as the guest (internal/versions: v1.35.5).
#
# Four things CANNOT be the same, and each is a deliberate, documented
# deviation (see docs/p82-kyverno-kind-control-2026-08-29.md):
#   1. namespace — the guest has only `default`, so harness/transform/render.go
#      pins `helm template --namespace default`; kind installs into `kyverno`,
#      the upstream chart's own namespace. This is the deviation the control
#      exists to measure: kyverno's generated namespaceSelector excludes its
#      own install namespace, so a `default`-namespace test is invisible to the
#      webhook on VM harness and visible to it on kind.
#   2. --serverIP=127.0.0.1:9443 — the guest has no Services (transform
#      .StripServices), so the entry uses kyverno's out-of-cluster lever to
#      publish a loopback URL clientConfig. kind has kube-proxy and a real
#      Service, so it uses the chart's normal Service clientConfig.
#   3. probes — the guest strips liveness/readiness probes; kind keeps them.
#   4. helm hooks — StripHooks on the guest, `--no-hooks` here.
#
# CONTROLLERS=all (default: admission) also runs background-controller and
# reports-controller from the pinned binaries, layering values-all.yaml; it
# must match the -controllers value p82-kind-sweep records for the run.
#
# UPSTREAM_CI=1 installs with Kyverno's own CI values
# ($KYVERNO_ROOT/scripts/config/standard/kyverno.yaml) layered UNDER ours, to
# match a p82-sweep/p82-kind-sweep -upstream-ci run.
#
# CI_SHAPED=1 (X38) brings the cluster up the way one Kyverno CI shard does:
# `scripts/config/resources/kyverno.yaml` then each config in KYVERNO_CONFIGS
# (comma list, default `standard`) layered under ours, KIND_CONFIG as the kind
# config, a server-side dry-run to verify the webhook path before tests start,
# and no boot-smoke policy or sanitize baseline (CI runs neither).
# INSTALL_KUBECTL_EVICT=1 for the jobs that need it. Images are built once and
# reused, so image_build_ms is ~0 after the first cluster. Deviations from CI's
# `make kind-install-kyverno` that remain: pinned side-loaded binaries, seed
# CRDs applied out of band (crds.install=false), and no cleanup controller (no
# pinned binary for it).
#
# Usage: [CONTROLLERS=all] [UPSTREAM_CI=1] [CI_SHAPED=1] up.sh <cluster-name> <kubeconfig-path>
set -euo pipefail

NAME="${1:?usage: up.sh <cluster-name> <kubeconfig>}"
KCFG="${2:?}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="${P82_SUT_DIR:-$REPO_ROOT/artifacts/sut/kyverno-admission}"
SEED_POLICY="$REPO_ROOT/examples/discovery/kyverno-admission/seed.yaml"

KIND="${KIND:-kind}"
# Pinned to the guest's Kubernetes profile (internal/versions/versions.json
# default_k8s 1.35 -> v1.35.5). A different minor would make an API-surface
# difference read as a substrate difference.
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95}"
CONTROLLERS="${CONTROLLERS:-admission}"
case "$CONTROLLERS" in
  admission) BINS="kyverno kyvernopre"; EXTRA_VALUES=() ;;
  all) BINS="kyverno kyvernopre background-controller reports-controller"
       EXTRA_VALUES=(-f "$(dirname "${BASH_SOURCE[0]}")/values-all.yaml") ;;
  # X72 (kc172): admission + the cleanup controller, the same
  # cmd/cleanup-controller binary (commit 945ac9ce) the kyverno-cleanup entry
  # runs, taken from CLEANUP_SUT (default artifacts/sut/kyverno-cleanup).
  cleanup) BINS="kyverno kyvernopre cleanup-controller"
       EXTRA_VALUES=(-f "$(dirname "${BASH_SOURCE[0]}")/values-cleanup.yaml") ;;
  *) echo "CONTROLLERS must be admission, all or cleanup, got '$CONTROLLERS'" >&2; exit 1 ;;
esac

UPSTREAM_VALUES=()
KIND_ARGS=()
CI_SHAPED="${CI_SHAPED:-}"
if [ "$CI_SHAPED" = 1 ]; then
  root="${KYVERNO_ROOT:-/tmp/kyverno-p82}"
  UPSTREAM_VALUES=(-f "$root/scripts/config/resources/kyverno.yaml")
  IFS=, read -ra cfgs <<< "${KYVERNO_CONFIGS:-standard}"
  for c in "${cfgs[@]}"; do
    [ -f "$root/scripts/config/$c/kyverno.yaml" ] || { echo "missing $root/scripts/config/$c/kyverno.yaml" >&2; exit 1; }
    UPSTREAM_VALUES+=(-f "$root/scripts/config/$c/kyverno.yaml")
  done
  if [ -n "${KIND_CONFIG:-}" ]; then KIND_ARGS=(--config "$root/${KIND_CONFIG#./}"); fi
  # X11: CI's kind configs publish host ports 80/443 from the control plane,
  # which two clusters on one host cannot both hold. CI never runs two at once;
  # the matched comparison does, so it drops the mappings (no selected test
  # reaches the cluster through a host port) and records that it did.
  if [ "${KIND_NO_HOST_PORTS:-}" = 1 ]; then
    stripped="$(mktemp --suffix=.yaml)"
    trap 'rm -f "$stripped"' EXIT
    # Let Docker allocate the API port while binding it. Kind's default
    # free-port probe releases the socket before docker run, so concurrent
    # cluster creation can select the same port. These clusters are disposable;
    # they do not need the port to survive a container restart.
    if [ -n "${KIND_CONFIG:-}" ]; then
      yq eval 'del(.nodes[].extraPortMappings) | .networking.apiServerPort = -1' "$root/${KIND_CONFIG#./}" > "$stripped"
    else
      printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnetworking:\n  apiServerPort: -1\n' > "$stripped"
    fi
    KIND_ARGS=(--config "$stripped")
  fi
elif [ "${UPSTREAM_CI:-}" = 1 ]; then
  f="${KYVERNO_ROOT:-/tmp/kyverno-p82}/scripts/config/standard/kyverno.yaml"
  [ -f "$f" ] || { echo "UPSTREAM_CI=1 but $f is missing" >&2; exit 1; }
  UPSTREAM_VALUES=(-f "$f")
fi

[ -x "$SUT/kyverno" ] || { echo "missing $SUT/kyverno: run 'make -C examples/discovery/kyverno-admission fetch-sut'" >&2; exit 1; }

# --- images: the pinned SUT binaries, not an upstream pull -------------------
build_images() {
  local ctx; ctx="$(mktemp -d)"; trap 'rm -rf "$ctx"' RETURN
  CLEANUP_SUT="${CLEANUP_SUT:-$REPO_ROOT/artifacts/sut/kyverno-cleanup}"
  for b in $BINS; do
    if [ "$b" = cleanup-controller ]; then cp "$CLEANUP_SUT/$b" "$ctx/"; else cp "$SUT/$b" "$ctx/"; fi
  done
  cp /etc/ssl/certs/ca-certificates.crt "$ctx/"
  for b in $BINS; do
    cat > "$ctx/Dockerfile.$b" <<EOF
FROM scratch
COPY ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY $b /$b
ENTRYPOINT ["/$b"]
EOF
  done
  for b in $BINS; do
    if [ "$CI_SHAPED" = 1 ] && docker image inspect "p82/$b:v1.18.2" >/dev/null 2>&1; then continue; fi
    docker build -q -f "$ctx/Dockerfile.$b" -t "p82/$b:v1.18.2" "$ctx" >/dev/null
  done
}

t0=$(date +%s.%N)
build_images
t_img=$(date +%s.%N)
# X11: build (or confirm) the images and stop, so concurrent clusters later
# never race on a first build.
if [ "${BUILD_IMAGES_ONLY:-}" = 1 ]; then exit 0; fi

# X84: every kind node runs systemd, kubelet, containerd and the control
# plane, each holding inotify instances against ONE per-user quota (the nodes'
# root processes all count as root), so a second concurrent cluster, and by 8
# or 16 certainly, exhausts the common default (128 instances) with "too many
# open files" in kubelet start or a node that never becomes ready. Fail here,
# naming the value, rather than minutes later inside kind. 512/524288 are
# kind's documented known-issue values; a caller running P clusters at once
# raises KIND_MIN_INOTIFY_INSTANCES (hack/p82-kind/parallel-campaign.sh does).
need_inst="${KIND_MIN_INOTIFY_INSTANCES:-512}"
need_watch="${KIND_MIN_INOTIFY_WATCHES:-524288}"
have_inst="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
have_watch="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
if [ "$have_inst" -lt "$need_inst" ] || [ "$have_watch" -lt "$need_watch" ]; then
  echo "up.sh: kind needs fs.inotify.max_user_instances >= $need_inst (is $have_inst) and fs.inotify.max_user_watches >= $need_watch (is $have_watch)." >&2
  echo "up.sh: raise them, e.g. sudo sysctl -w fs.inotify.max_user_instances=$need_inst fs.inotify.max_user_watches=$need_watch" >&2
  exit 1
fi

"$KIND" create cluster --name "$NAME" --image "$NODE_IMAGE" --kubeconfig "$KCFG" "${KIND_ARGS[@]}" >/dev/null
# X11 equal host allocation: node containers are dockerd's children, outside
# any scope the caller can wrap, so their CPU set and memory cap are applied
# here, before anything is installed. Swap is capped with memory (no spill).
if [ -n "${KIND_NODE_CPUSET:-}${KIND_NODE_MEMORY:-}" ]; then
  for c in $(docker ps -q --filter "label=io.x-k8s.kind.cluster=$NAME"); do
    docker update ${KIND_NODE_CPUSET:+--cpuset-cpus "$KIND_NODE_CPUSET"} \
      ${KIND_NODE_MEMORY:+--memory "$KIND_NODE_MEMORY" --memory-swap "$KIND_NODE_MEMORY"} "$c" >/dev/null
  done
fi
t_create=$(date +%s.%N)

# shellcheck disable=SC2046
"$KIND" load docker-image --name "$NAME" $(for b in $BINS; do echo "p82/$b:v1.18.2"; done) >/dev/null 2>&1
t_load=$(date +%s.%N)

export KUBECONFIG="$KCFG"
kubectl create namespace kyverno >/dev/null
# The same crdGlob the entry seeds (sut.yaml), applied server-side: several
# kyverno CRDs exceed the client-side last-applied annotation limit. The glob
# selects the `<group>_<plural>.yaml` CRD files only -- seed.yaml is the
# boot-smoke ClusterPolicy and must wait until its CRD and the webhook exist.
for f in "$SUT"/seed/*_*.yaml; do kubectl apply --server-side -f "$f" >/dev/null; done

# CI's "Install OpenReports" step (conformance/run/action.yaml): the reports
# controller with the openreports config waits on these CRDs, so without them
# `helm install --wait` times out. The URL tracks upstream main, exactly as CI's
# does; the digest is logged so a run can be tied to what was applied.
if [ "${INSTALL_OPENREPORTS:-}" = 1 ]; then
  OR_YAML=$(curl -fsSL https://raw.githubusercontent.com/openreports/reports-api/refs/heads/main/config/install.yaml)
  echo "openreports install.yaml sha256 $(printf %s "$OR_YAML" | sha256sum | cut -c1-16)" >&2
  printf %s "$OR_YAML" | kubectl apply -f - >/dev/null
fi
# CI's `make kind-install-kyverno` names the release `kyverno`, which makes the
# chart's ConfigMap `kyverno`; tests patch it by that name. `harness` yields
# `harness-kyverno`, so the events tests failed and failFast skipped the rest.
REL=harness; [ "$CI_SHAPED" = 1 ] && REL=kyverno
helm install "$REL" "$SUT/chart" -n kyverno --no-hooks "${UPSTREAM_VALUES[@]}" \
  -f "$(dirname "${BASH_SOURCE[0]}")/values.yaml" "${EXTRA_VALUES[@]}" --wait --timeout 10m >/dev/null
t_install=$(date +%s.%N)

# `helm --wait` and Deployment Available are not sufficient: the Service's
# EndpointSlice and kube-proxy rules can lag pod readiness. Wait for a ready
# endpoint in both modes. Baseline mode then applies the boot-smoke policy,
# which remains part of its persistent state. CI_SHAPED instead server-side
# dry-runs that policy: this exercises the existing mutate-policy admission
# route without adding a fixture policy to the upstream CI test environment.
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=5m >/dev/null
svc=$(kubectl -n kyverno get svc -o name | sed -n 's|^service/\(.*-svc\)$|\1|p' | head -1)
[ -n "$svc" ] || { echo "up.sh: no kyverno webhook Service (*-svc) in ns kyverno" >&2; exit 1; }
deadline=$(( $(date +%s) + 120 ))
until kubectl -n kyverno get endpointslices -l "kubernetes.io/service-name=$svc" \
    -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' | grep -q .; do
  [ "$(date +%s)" -lt "$deadline" ] || { echo "up.sh: no ready endpoint for svc/$svc after 120s" >&2; exit 1; }
  sleep 1
done
deadline=$(( $(date +%s) + 60 ))
if [ "$CI_SHAPED" = 1 ]; then
  until err=$(kubectl apply --dry-run=server -f "$SEED_POLICY" 2>&1 >/dev/null); do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "$err" >&2; exit 1; }
    sleep 2
  done
else
  until err=$(kubectl apply -f "$SEED_POLICY" 2>&1 >/dev/null); do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "$err" >&2; exit 1; }
    sleep 2
  done
fi
if [ "$CONTROLLERS" = cleanup ]; then
  # The chart grants the cleanup controller no delete on any target kind; the
  # entry's operator.yaml adds delete on ConfigMaps, so do the same through the
  # chart's own aggregation label.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: t172-cleanup-configmaps
  labels:
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "delete"]
EOF
  kubectl -n kyverno rollout status deploy/kyverno-cleanup-controller --timeout=5m >/dev/null
fi
if [ "$CONTROLLERS" = all ]; then
  kubectl -n kyverno rollout status deploy/kyverno-background-controller --timeout=5m >/dev/null
  kubectl -n kyverno rollout status deploy/kyverno-reports-controller --timeout=5m >/dev/null
fi
t_ready=$(date +%s.%N)
if [ "$CI_SHAPED" = 1 ]; then
  if [ "${INSTALL_KUBECTL_EVICT:-}" = 1 ]; then
    GOBIN="${GOBIN:-$HOME/go/bin}" go install github.com/ueokande/kubectl-evict@latest >/dev/null 2>&1 || echo "WARNING: kubectl-evict install failed" >&2
  fi
  t_extras=$(date +%s.%N)
  ms() { echo "$1 $2" | awk '{printf "%.0f", ($2-$1)*1000}'; }
  cat <<JSON
{"phase":"kind_up","ci_shaped":true,"cluster":"$NAME","no_host_ports":${KIND_NO_HOST_PORTS:-0},"node_cpuset":"${KIND_NODE_CPUSET:-}","node_memory":"${KIND_NODE_MEMORY:-}","kyverno_configs":"${KYVERNO_CONFIGS:-standard}","image_build_ms":$(ms $t0 $t_img),"cluster_create_ms":$(ms $t_img $t_create),"image_load_ms":$(ms $t_create $t_load),"crds_and_helm_ms":$(ms $t_load $t_install),"wait_ready_ms":$(ms $t_install $t_ready),"extras_ms":$(ms $t_ready $t_extras),"total_ms":$(ms $t0 $t_extras)}
JSON
  exit 0
fi

# The post-install contents of the namespaces sanitize.sh keeps (its
# KEPT_NAMESPACES; keep the two lists in step), so it can
# delete what a directory added to them without deleting the namespace itself.
# Written next to the kubeconfig, which is the one path sanitize.sh is given.
kubectl api-resources --namespaced=true --verbs=list,delete -o name 2>/dev/null \
  | grep -Ev '^(events|events\.events\.k8s\.io)$' | paste -sd, - > "$KCFG.sanitize-types"
for ns in default kube-system kube-public kube-node-lease kyverno local-path-storage; do
  kubectl -n "$ns" get "$(cat "$KCFG.sanitize-types")" -o name 2>/dev/null | sed "s|^|$ns |"
done | LC_ALL=C sort > "$KCFG.sanitize-baseline"

ms() { echo "$1 $2" | awk '{printf "%.0f", ($2-$1)*1000}'; }
cat <<EOF
{"phase":"kind_up","cluster":"$NAME","image_build_ms":$(ms $t0 $t_img),"cluster_create_ms":$(ms $t_img $t_create),"image_load_ms":$(ms $t_create $t_load),"crds_and_helm_ms":$(ms $t_load $t_install),"seed_policy_ms":$(ms $t_install $t_ready),"total_ms":$(ms $t0 $t_ready)}
EOF
