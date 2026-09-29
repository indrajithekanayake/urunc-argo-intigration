### Understanding Argo Workflows execution model (with `runc`)

I'm using a k8s cluster built with kubeadm to understand mechanically what Argo Workflows does on a machine (Please note that I do not have access to a bare-metal machine, so I am working on an Ubuntu VM with nested KVM virtualization). I'm not using a logging stack because I think it will make the logs messy by spawning so many processes (Flannel is chosen over Calico also for the same reason). Priority is given to logging processes and I'm using;

1. `journalctl` for service logs
2. `kubectl logs` for container logs
3. `snap.sh` for snapshots; _Also, AI suggested process-level tracing uses BPF `execsnoop` instead of `auditd` for spawn sequence tracing (which I'm not much familiar with). But will test that too_

So I'm running `experiment.yaml` which will write **EXPERIMENT-BEGIN** marker to `stderr` and the result to `stdout`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: experiment-
spec:
  entrypoint: demo
  templates:
    - name: demo
      script:
        image: python:alpine3.23
        command: [python]
        source: |
          import sys, time
          print("EXPERIMENT-BEGIN", file=sys.stderr, flush=True)
          time.sleep(300)
          print("42")
```

The `sleep(300)` keeps the pod running long enough to snapshot the emptyDirs before kubelet reclaims them.

> Later, once we have a basic POC, we need to test the other two types of Argo Workflows with unikernels (i.e., DAGs and sequential workflows)

---

## Cluster setup

Ubuntu 24.04, kernel 6.8.0, 4 vCPU / 7.8 GB, no swap. Each component is installed separately so that a failure can be traced to the layer it came from.

```bash
# 1. host prerequisites
cat >/etc/modules-load.d/k8s.conf <<<$'overlay\nbr_netfilter'
modprobe overlay && modprobe br_netfilter
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system

# 2. runc v1.5.1
curl -fsSL -o /tmp/runc https://github.com/opencontainers/runc/releases/download/v1.5.1/runc.amd64
install -m 755 /tmp/runc /usr/local/sbin/runc

# 3. containerd v2.4.0  (NOTE: 2.x uses config version 4, CRI plugin renamed)
curl -fsSL https://github.com/containerd/containerd/releases/download/v2.4.0/containerd-2.4.0-linux-amd64.tar.gz \
  | tar Cxz /usr/local
curl -fsSL -o /usr/local/lib/systemd/system/containerd.service \
  https://raw.githubusercontent.com/containerd/containerd/v2.4.0/containerd.service
containerd config default > /etc/containerd/config.toml     # generate, never hand-write
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl daemon-reload && systemctl enable --now containerd

# 4. CNI plugins v1.9.1 + crictl v1.37.0
mkdir -p /opt/cni/bin
curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz \
  | tar Cxz /opt/cni/bin
curl -fsSL https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.37.0/crictl-v1.37.0-linux-amd64.tar.gz \
  | tar Cxz /usr/local/bin
printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\n' \
  > /etc/crictl.yaml

# 5. kubeadm / kubelet / kubectl v1.37.0
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y kubelet kubeadm kubectl && apt-mark hold kubelet kubeadm kubectl

# 6. control plane  (pin the advertise address if the host has >1 NIC)
kubeadm config images pull
kubeadm init --pod-network-cidr=10.244.0.0/16 \
             --apiserver-advertise-address=<NODE_IP> \
             --cri-socket=unix:///run/containerd/containerd.sock
mkdir -p ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config

# 7. Flannel — pin --iface too, autodetection is a coin flip with 2 NICs
kubectl apply -f manifests/kube-flannel.yml
kubectl taint nodes --all node-role.kubernetes.io/control-plane-   # single node: required

# 8. Argo Workflows v4.1.4
kubectl create namespace argo
kubectl apply -n argo --server-side=true -f argo-install.yaml      # CRDs exceed the annotation limit
kubectl apply -f manifests/executor-rbac.yaml                      # else: workflowtaskresults is forbidden
```

Two steps above are easy to miss. The control-plane node must be untainted, otherwise workflow pods remain `Pending` on a single-node cluster. `executor-rbac.yaml` must be applied separately, because `install.yaml` grants no permissions to the workflow's ServiceAccount; the `wait` container needs `create` and `patch` on `workflowtaskresults` to report results back. I applied the Role before the first submit, so I have not seen that failure myself.

Then run it:

```bash
argo submit -n argo manifests/experiment.yaml
scripts/snap.sh live-running argo        # WHILE main still sleeps — volumes only exist now
argo wait -n argo <workflow>
scripts/snap.sh final-complete argo
```

---

## What I found

The original unpacked argoexec image (comes from `quay.io/argoproj/argoexec:v4.1.4`) is basically around 166.6MB and at the usual location for all unpacked images `/var/lib/containerd/`. Both `init` and `wait` containers spawn from this image. But they never co-exist. In the above example, `init` ran and exited before either of the other two workload containers started, 11:28:43.197 → 11:28:43.283 (the sandbox `/pause` was already up at 11:28:42).

| Container | Image | Created | Started | Finished | Alive | Exit |
|-----------|-------|---------|---------|----------|------:|-----:|
| init | `quay.io/argoproj/argoexec:v4.1.4` | 11:28:43.150 | 11:28:43.197 | 11:28:43.283 | 0.087 s | 0 |
| wait | `quay.io/argoproj/argoexec:v4.1.4` | 11:28:47.304 | 11:28:47.431 | 11:33:48.001 | 300.570 s | 0 |
| main | `python:alpine3.23` | 11:28:47.700 | 11:28:47.768 | 11:33:47.889 | 300.121 s | 0 |

**Interestingly enough**, before `init` exits it copies the argoexec executable/binary (the image is basically one Go executable/binary, so same size as above; 166.6MB) into `/var-run-argo/argoexec` emptyDir for the `main` container to use.

ex (look at the copied argoexec binary snapshot below):

```sh
/var/lib/kubelet/pods/c6903810-78f0-485c-8bf7-f39d6b3e552c/volumes/kubernetes.io~empty-dir/var-run-argo/argoexec     166,569,319 bytes
```

`var-run-argo` is not the only emptyDir we are dealing with here. Three emptyDirs are created per pod and destroyed when that pod dies. Its path is keyed by the **pod UID**. I think it would be better to put in a diagram.

<img width="2991" height="1496" alt="image" src="https://github.com/user-attachments/assets/951032a0-5241-4881-9b35-20c8257a4248" />

> In addition to the emptyDirs' there is a [projected volume](https://kubernetes.io/docs/concepts/storage/projected-volumes/) mounting the service-account token to **all three** containers read-only. Only `wait` ever uses it (because `wait` requires the executor Role to communicate the exit code to the API server, and the ServiceAccount credential materials are stored in this projected-volume).

The `main` actually does the **craziest part**. Instead of letting runc launch `python /argo/staging/script`, `main` launches it as a child under the argoexec emissary with `/var/run/argo/argoexec emissary -- python /argo/staging/script`

<img width="3087" height="965" alt="image" src="https://github.com/user-attachments/assets/37db92ec-35e0-4690-8365-52eec2816e40" />

> `wait` logged completion 1 ms after emissary logged sub-process exited — 11:33:47.886 → 11:33:47.887 (so I'm assuming it's a file watch)

> Also, I noticed `stdout` 42 is only printed in the terminal. Since our workflow is a single step with nothing after, Argo skips capturing the `stdout`. This was printed in the `init` and `wait` container logs as `includeScriptOutput=false`. **Test this behavior again when running multi step, DAG workflow. When another pod references the script's `stdout` result this must become true**

BPF `execsnoop` was started before the workflow was submitted, so every exec below is caused by this pod/sandbox. I've used a Python script (`scripts/runc-trace.py`) to reconstruct the spawn sequence below from the execsnoop trace (`logs/process/execsnoop.pod-only.log`)

| TIME | TREE (indent = ancestry) | PID | CONTAINER |
|---|---|---:|---|
|  | `containerd` | 96334 |  |
| 11:28:42 | `└─ shim SPAWN` | 98658 | sandbox |
| 11:28:42 | `   └─ shim SERVE ← the pod's shim` | 98666 | sandbox |
| 11:28:42 | `      └─ runc create` | 98677 | sandbox |
| 11:28:42 | `      └─ runc start` | 98696 | sandbox |
| **11:28:42** | **`      └─ pause` ← ENTRYPOINT** | **98690** | **sandbox** |
| 11:28:43 | `      └─ runc create` | 98703 | init |
| 11:28:43 | `      └─ runc start` | 98723 | init |
| **11:28:43** | **`      └─ argoexec init` ← ENTRYPOINT** | **98717** | **init** |
| 11:28:43 | `      └─ runc kill --all` | 98737 | init |
| 11:28:43 | `      └─ runc delete` | 98743 | init |
| 11:28:46 | `└─ shim REAP` | 98753 | init |
| 11:28:46 | `   └─ runc delete --force` | 98761 | init |
| 11:28:47 | `      └─ runc create` | 98789 | wait |
| 11:28:47 | `      └─ runc start` | 98808 | wait |
| **11:28:47** | **`      └─ argoexec wait` ← ENTRYPOINT** | **98801** | **wait** |
| 11:28:47 | `      └─ runc create` | 98822 | main |
| 11:28:47 | `      └─ runc start` | 98842 | main |
| **11:28:47** | **`      └─ argoexec emissary` ← ENTRYPOINT** | **98836** | **main** |
| 11:28:47 | `         └─ python /argo/staging/script` | 98858 | main |
| 11:33:47 | `      └─ runc kill --all` | 106595 | main |
| 11:33:47 | `      └─ runc delete` | 106601 | main |
| 11:33:47 | `└─ shim REAP` | 106608 | main |
| 11:33:47 | `   └─ runc delete --force` | 106616 | main |
| 11:33:48 | `      └─ runc kill --all` | 106621 | wait |
| 11:33:48 | `      └─ runc delete` | 106627 | wait |
| 11:33:49 | `└─ shim REAP` | 106645 | wait |
| 11:33:49 | `   └─ runc delete --force` | 106653 | wait |
| 11:33:50 | `      └─ runc kill` | 106659 | sandbox |
| 11:33:50 | `      └─ runc kill --all` | 106666 | sandbox |
| 11:33:50 | `      └─ runc delete` | 106672 | sandbox |
| 11:33:50 | `└─ shim REAP` | 106678 | sandbox |
| 11:33:50 | `   └─ runc delete --force` | 106686 | sandbox |

---

## Scanning the logs

```bash
# the three containers separately — `kubectl logs <pod>` alone shows only main,
# because Argo sets the annotation kubectl.kubernetes.io/default-container: main
cat logs/kubectl/{init,wait,main}.log

# CRI ground truth: same lines, but with the stdout/stderr markers kubectl strips
cat logs/podlogs/main/0.log

# why the pod was created at all — the controller's decisions about it
cat logs/kubectl/workflow-controller.log

# container id -> name -> host PID -> cgroup, the table that joins all three planes
cat logs/cri/container-pid-map.txt

# the runc-level lifecycle, ancestry shown as indentation
cat logs/process/runc-trace.depth.txt

# what was actually on the shared volumes, before and after the pod died
cat logs/volumes/while-running/tree.txt
cat logs/volumes/after-completion/tree.txt
cat logs/volumes/while-running/argo-staging--script

# kubelet / containerd, filtered to this pod
cat logs/journalctl/kubelet.pod-only.log
cat logs/journalctl/containerd.cri-calls.log
```

Rebuild the spawn table yourself from a raw trace:

```bash
python3 scripts/runc-trace.py <execsnoop.log> <capture-dir>          # time-ordered
python3 scripts/runc-trace.py <execsnoop.log> <capture-dir> --depth  # ancestry tree
```

On a live cluster:

```bash
kubectl logs -n argo <pod> -c init          # -c is required; init and wait are hidden otherwise
kubectl logs -n argo <pod> -c wait
journalctl -u kubelet -u containerd -f      # both planes interleaved
crictl ps -a && crictl inspect <id> | jq '.info.pid'
```

---

## Layout

```
manifests/      experiment.yaml, executor-rbac.yaml, kube-flannel.yml (--iface pinned)
scripts/        snap.sh (snapshots), runc-trace.py (rebuilds the spawn sequence)
logs/
  kubectl/      per-container logs, controller decisions, describe, pod/workflow yaml
  podlogs/      CRI ground truth with stdout/stderr stream markers
  journalctl/   kubelet + containerd, filtered to this pod
  cri/          crictl ps/pods, per-container inspect, container-pid-map.txt
  process/      execsnoop (pod subtree), runc-trace flat + depth, ps forest, cgroups
  volumes/      the emptyDir contents, while running and after completion
```

Every log here belongs to one run — workflow `experiment-k42z6`, pod UID
`c6903810-78f0-485c-8bf7-f39d6b3e552c`, 11:28:38 → 11:33:57 UTC. The raw execsnoop
trace contained 6,408 execs, of which 35 belong to this pod. The remainder
(kube-proxy iptables activity, CoreDNS, etcd, and my own `kubectl` and
`crictl` commands) has been filtered out.

Versions: kubeadm/kubelet/kubectl v1.37.0, containerd v2.4.0, runc v1.5.1,
CNI plugins v1.9.1, Flannel v0.28.9, Argo Workflows v4.1.4.
