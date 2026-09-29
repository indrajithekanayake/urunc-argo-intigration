#!/usr/bin/env bash
# snap.sh <label> [namespace] - freeze ephemeral Argo/K8s/runtime/process state.
# Argo pods finish in seconds; this captures the moment before it evaporates.
set -uo pipefail

LABEL="${1:-snap}"
NS="${2:-argo}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="/root/argo-lab/captures/${TS}-${LABEL}"
mkdir -p "$OUT"/{k8s,runtime,process,podlogs,journal,volumes}

log(){ printf '  %-28s %s\n' "$1" "$2"; }
run(){ local f="$1"; shift; "$@" >"$f" 2>&1; }

echo "[snap] -> $OUT"

### Plane 1: Kubernetes / orchestration
run "$OUT/k8s/workflows.yaml"      kubectl get wf -n "$NS" -o yaml
run "$OUT/k8s/workflows.txt"       kubectl get wf -n "$NS" -o wide
run "$OUT/k8s/pods.yaml"           kubectl get pods -n "$NS" -o yaml
run "$OUT/k8s/pods-wide.txt"       kubectl get pods -n "$NS" -o wide
run "$OUT/k8s/events.txt"          kubectl get events -n "$NS" --sort-by=.lastTimestamp
run "$OUT/k8s/nodes.txt"           kubectl get nodes -o wide
run "$OUT/k8s/controller.log"      kubectl logs -n argo deploy/workflow-controller --tail=300
log "kubernetes" "workflows, pods, events, controller"

# Per-pod: describe + logs from EVERY container (kubectl logs defaults to main only)
for pod in $(kubectl get pods -n "$NS" -o name 2>/dev/null | cut -d/ -f2); do
  kubectl describe pod -n "$NS" "$pod" > "$OUT/k8s/describe-${pod}.txt" 2>&1
  for c in $(kubectl get pod -n "$NS" "$pod" \
               -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null); do
    kubectl logs -n "$NS" "$pod" -c "$c"            > "$OUT/k8s/logs-${pod}-${c}.log"      2>&1
    kubectl logs -n "$NS" "$pod" -c "$c" --previous > "$OUT/k8s/logs-${pod}-${c}.prev.log" 2>&1
    # --previous writes an error when there is no prior instance: that is noise, not evidence
    pf="$OUT/k8s/logs-${pod}-${c}.prev.log"
    if [ ! -s "$pf" ] || grep -q 'previous terminated container' "$pf" 2>/dev/null; then rm -f "$pf"; fi
  done
done
log "pod logs" "all containers incl. init + wait"

### Plane 2: container runtime (CRI)
run "$OUT/runtime/crictl-ps.txt"    crictl ps -a
run "$OUT/runtime/crictl-pods.txt"  crictl pods
run "$OUT/runtime/crictl-images.txt" crictl images
run "$OUT/runtime/crictl-info.json" crictl info
for cid in $(crictl ps -a -q 2>/dev/null); do
  crictl inspect "$cid" > "$OUT/runtime/inspect-${cid:0:12}.json" 2>&1
done
# container id -> host PID map: the bridge between runtime and process planes
{
  printf '%-14s %-34s %-8s %s\n' CONTAINER NAME PID CGROUP
  for cid in $(crictl ps -q 2>/dev/null); do
    j=$(crictl inspect "$cid" 2>/dev/null)
    nm=$(jq -r '.status.metadata.name // "?"'  <<<"$j")
    pid=$(jq -r '.info.pid // "?"'             <<<"$j")
    cg=$(jq -r '.info.runtimeSpec.linux.cgroupsPath // "?"' <<<"$j")
    printf '%-14s %-34s %-8s %s\n' "${cid:0:12}" "$nm" "$pid" "$cg"
  done
} > "$OUT/runtime/container-pid-map.txt" 2>&1
log "runtime" "crictl ps/inspect + container->PID map"

### Plane 3: Linux processes & cgroups
run "$OUT/process/ps-forest.txt"  ps -ef --forest
run "$OUT/process/ps-full.txt"    ps -eo pid,ppid,pgid,stat,comm,args
{ command -v systemd-cgls >/dev/null && systemd-cgls --no-pager; } > "$OUT/process/cgls.txt" 2>&1
find /sys/fs/cgroup/kubepods.slice -maxdepth 5 -name cgroup.procs 2>/dev/null \
  | while read -r f; do
      pids=$(tr '\n' ' ' < "$f" 2>/dev/null)
      [ -n "${pids// /}" ] && printf '%s\n    %s\n' "${f%/cgroup.procs}" "$pids"
    done > "$OUT/process/cgroup-tree.txt" 2>&1
# argoexec / emissary argv straight from /proc - the real evidence
# pgrep -f matches the pattern against EVERY command line, including this
# script's own shell - confirm argv[0] really is the argoexec binary
{ for p in $(pgrep -f argoexec 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    a0=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -1)
    [ "$(basename "${a0:-none}")" = "argoexec" ] || continue
    echo "=== PID $p ==="
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null; echo
    echo "  cgroup: $(sed -n 's/^0:://p' /proc/$p/cgroup 2>/dev/null)"
  done; } > "$OUT/process/argoexec-procs.txt" 2>&1
log "process" "ps forest, cgroup tree, argoexec argv"

### Tier 0 + Tier 1 log planes
journalctl -u kubelet    --since "10 min ago" --no-pager > "$OUT/journal/kubelet.log"    2>&1
journalctl -u containerd --since "10 min ago" --no-pager > "$OUT/journal/containerd.log" 2>&1
for d in /var/log/pods/${NS}_*; do
  [ -d "$d" ] && cp -r "$d" "$OUT/podlogs/" 2>/dev/null
done
log "journald + /var/log/pods" "kubelet, containerd, CRI ground truth"

### Pod emptyDir volumes (reclaimed at teardown - only present while pod is alive)
for pod in $(kubectl get pods -n "$NS" -o name 2>/dev/null | cut -d/ -f2); do
  u=$(kubectl get pod -n "$NS" "$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  [ -n "$u" ] || continue
  vd="/var/lib/kubelet/pods/$u/volumes/kubernetes.io~empty-dir"
  [ -d "$vd" ] || continue
  # record the tree, and copy files under 1MiB (-1048576c: byte units, NOT -1M which rounds up)
  find "$vd" -mindepth 1 -printf '%TY-%Tm-%Td %TH:%TM:%.2TS  %y %12s  %p\n' \
    > "$OUT/volumes/tree-${pod}.txt" 2>&1
  # an empty tree is meaningful, but say so rather than leaving a 0-byte file
  [ -s "$OUT/volumes/tree-${pod}.txt" ] || \
    echo "(no emptyDir volumes present - pod had terminated and kubelet reclaimed them)" \
      > "$OUT/volumes/tree-${pod}.txt"
  find "$vd" -type f -size -1048576c -print0 2>/dev/null | while IFS= read -r -d '' f; do
    rel="${f#$vd/}"; mkdir -p "$OUT/volumes/${pod}/$(dirname "$rel")"
    cp "$f" "$OUT/volumes/${pod}/$rel" 2>/dev/null
  done
done
log "pod volumes" "emptyDir trees + staged files (<1M)"

du -sh "$OUT" | awk '{print "[snap] done: "$1"  "$2}'
