#!/usr/bin/env python3
"""runc-trace.py [execsnoop.log] [capture-dir]

Reconstruct the complete runc-level container lifecycle for ONE pod.

Anchor: containerd runs one long-lived shim per pod sandbox. Every runc
invocation and every container entrypoint is its child; anything running
inside a container descends from one of those entrypoints. A transitive PID
closure from that shim isolates exactly one pod from all host noise.

Caveat the naive greps miss: runc's container ID is the LAST argument, not
the one after the verb ('create --bundle X --pid-file Y <id>'), and kill
carries '--all' between verb and id. Parsing by position silently drops
every create and most kills.
"""
import sys, re, json, glob, os, collections

log = sys.argv[1] if len(sys.argv) > 1 else "/root/argo-lab/captures/execsnoop.log"
cap = sys.argv[2] if len(sys.argv) > 2 else "/root/argo-lab/captures/20260919-113414-final-complete"

names = {}
for f in glob.glob(os.path.join(cap, "runtime", "inspect-*.json")):
    cid = os.path.basename(f)[len("inspect-"):-len(".json")]
    try:
        names[cid] = json.load(open(f))["status"]["metadata"]["name"]
    except Exception:
        pass

rows = []
for line in open(log):
    p = line.split(None, 5)
    if len(p) < 5 or p[0] == "TIME" or not p[2].isdigit():
        continue
    rows.append(dict(t=p[0], comm=p[1], pid=int(p[2]), ppid=int(p[3]),
                     args=(p[5].rstrip("\n") if len(p) > 5 else "")))

shim = collections.Counter(r["ppid"] for r in rows if r["comm"] == "runc").most_common(1)[0][0]
spawn_shim = next((r["ppid"] for r in rows if r["pid"] == shim), None)
# containerd is the parent of the TRANSIENT shims, not of the long-lived one
containerd = next((r["ppid"] for r in rows if r["comm"] == "containerd-shim"
                   and r["pid"] != shim), None)

# transitive closure from the long-lived shim, PLUS the transient delete shims
# (those are children of containerd, so they need adding by container id)
keep = {shim}
for _ in range(10):
    grew = False
    for r in rows:
        if r["ppid"] in keep and r["pid"] not in keep:
            keep.add(r["pid"]); grew = True
    if not grew:
        break
POD_IDS = set()
for r in rows:
    if r["pid"] in keep:
        POD_IDS.update(m[:12] for m in re.findall(r"\b([0-9a-f]{64})\b", r["args"]))
for _ in range(3):
    for r in rows:
        if r["pid"] in keep: continue
        if any(i in r["args"] for i in POD_IDS) and r["comm"] in ("containerd-shim", "runc"):
            keep.add(r["pid"])

injected = False
VERB = re.compile(r"\s(create|start|kill|delete|exec)\s")
HEX  = re.compile(r"\b([0-9a-f]{64})\b")

def cid_of(a):
    ids = HEX.findall(a)
    return ids[-1][:12] if ids else None

print(f"containerd PID {containerd}   spawn-shim {spawn_shim}   long-lived shim {shim}   "
      f"{len(keep)} processes in this pod's subtree\n")
print(f"{'TIME':9} {'PID':>7} {'PPID':>7}  {'STEP':32} CONTAINER")
print("-" * 92)
for r in rows:
    if r["pid"] not in keep:
        continue
    a = r["args"]
    cid = cid_of(a) or (cid_of(a) if False else None)
    label = names.get(cid, "sandbox" if cid else "")
    if r["comm"] == "runc":
        v = VERB.search(a)
        v = v.group(1) if v else "?"
        flag = " --all" if "--all" in a else (" --force" if "--force" in a else "")
        if v == "exec": injected = True
        print(f"{r['t']:9} {r['pid']:>7} {r['ppid']:>7}  runc {v + flag:27} {label}")
    elif r["comm"] == "containerd-shim":
        kind = ("shim SPAWN (transient)" if a.rstrip().endswith("start")
                else "shim REAP (transient)" if a.rstrip().endswith("delete")
                else "shim SERVE (long-lived)")
        print(f"{r['t']:9} {r['pid']:>7} {r['ppid']:>7}  {kind:32} {label}")
    elif r["comm"] == "6" and a.endswith("init"):
        print(f"{r['t']:9} {r['pid']:>7} {r['ppid']:>7}  {'runc STAGE-2 (namespaces/cgroups)':32}")
    else:
        if r["ppid"] == shim and injected:
            where = "INJECTED by runc exec"; injected = False
        elif r["ppid"] == shim:
            where = "ENTRYPOINT (pid 1 in ctr)"
        else:
            where = "child inside container"
        print(f"{r['t']:9} {r['pid']:>7} {r['ppid']:>7}  {where:32} {a[:44]}")


# ---------------------------------------------------------------------------
# Depth view: same events, but indented by ancestry so parent->child is a
# column position rather than a PPID you have to match up by eye.
# Run with:  runc-trace.py <log> <capture> --depth
# ---------------------------------------------------------------------------
if "--depth" in sys.argv:
    parent = {r["pid"]: r["ppid"] for r in rows}
    roots = {containerd}

    def depth(pid, guard=0):
        d = 0
        while pid in parent and pid not in roots and guard < 20:
            pid = parent[pid]; d += 1; guard += 1
        return d

    describe_last = [""]
    def describe(r):
        a = r["args"]
        cid = cid_of(a)
        who = names.get(cid, "sandbox" if cid else "")
        if r["comm"] == "runc":
            v = VERB.search(a); v = v.group(1) if v else "?"
            fl = " --all" if "--all" in a else (" --force" if "--force" in a else "")
            if who: describe.last = who
            return f"runc {v}{fl}", who
        if r["comm"] == "containerd-shim":
            k = ("shim SPAWN" if a.rstrip().endswith("start")
                 else "shim REAP" if a.rstrip().endswith("delete") else "shim SERVE")
            if who: describe.last = who
            return k, who
        if r["comm"] == "6" and a.endswith("init"):
            return "stage-2 (runc re-exec)", ""
        # entrypoints carry no container id in argv: attribute to the most
        # recent runc create/start, and show what actually ran
        cmd = a.split()[0].split("/")[-1]
        rest = " ".join(a.split()[1:3])
        if r["comm"] == "argoexec":
            rest = a.split("argoexec")[-1].strip().split()[0]
            cmd = "argoexec"
        return f"{cmd} {rest}".strip()[:34], describe.last

    # a `runc exec` and everything under it is observer-induced (kubectl exec),
    # not something Argo does; mark it so the trace is not misread
    OBSERVER = set()
    for r in rows:
        if r["comm"] == "runc" and re.search(r"\sexec\s", r["args"]):
            OBSERVER.add(r["pid"])
    for _ in range(3):
        for r in rows:
            if r["ppid"] in OBSERVER or (r["ppid"] == shim and r["comm"] == "ps"):
                OBSERVER.add(r["pid"])

    describe.last = ""
    print("\n\nDEPTH VIEW  (indent = ancestry; same column = same parent)\n")
    print(f"{'TIME':9} {'TREE (indent by depth)':52} {'PID':>7}  CONTAINER")
    print("-" * 88)
    print(f"{'':9} {'containerd':52} {containerd:>7}")
    for r in rows:
        if r["pid"] not in keep:
            continue
        d = depth(r["pid"])
        what, who = describe(r)
        tree = "   " * d + ("└─ " if d else "") + what
        mark = "  [OBSERVER]" if r["pid"] in OBSERVER else ""
        print(f"{r['t']:9} {tree:52} {r['pid']:>7}  {who}{mark}")
