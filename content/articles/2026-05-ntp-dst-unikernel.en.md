---
title: "Making a Dumb NTP Clock Smart: DST Compensation with a Unikernel"
date: 2026-05-23T12:00:00+02:00
slug: ntp-dst-unikernel
cover:
  image: /images/2026-ntp-dst/mondaine-clock.jpg
tags: [ntp, golang, unikernel, nanos, oci, dst, embedded]
description: |
  My Mondaine SBB wall clock has a manual DST toggle but won't switch automatically.
  So I built a fake NTP server as a Nanos unikernel—running on OCI's free tier—to compensate.
---

My [Mondaine SBB wall
clock](https://lieven.kks36.be/2023/11/08/how-smart-is-the-mondaine-msm-25s11-wifi-wall-clock/)
looks great on the wall, but it has a fundamental flaw: it treats NTP time as UTC and applies a **fixed** offset. It does have a manual DST toggle, but every time change I'd need to take it off the wall, connect to its Wi-Fi, and flip the setting. Cumbersome enough that I prefer spending a few hours implementing a fake NTP server to compensate :)

So I built [ntp-dst](https://github.com/clementnuss/ntp-dst): a fake NTP server that compensates for DST transitions, running as a [Nanos](https://nanos.org) unikernel on [Oracle Cloud's free tier](https://www.oracle.com/cloud/free/). The compensated server is available at `dst-ntp.n8r.ch`—point your clock there and forget about DST.

Both this article and the code were heavily aided by GLM-5.1 + [OpenCode](https://opencode.ai) (though I still manually proofread and modify the blog post!).

## The Problem

The clock's behavior is simple:

| Season        | Correct offset | Clock offset | What the clock shows |
| ------------- | -------------- | ------------ | -------------------- |
| CET (winter)  | UTC+1          | +1h          | Correct              |
| CEST (summer) | UTC+2          | +1h          | 1 hour behind        |

## The Solution

Instead of fixing the clock, I fix the time it receives. The server gets the correct local time via Go's timezone data, then serves a shifted UTC so the clock's fixed offset still yields the right time:

```golang
zurich, err := time.LoadLocation("Europe/Zurich")
whatTheClockShouldShow = time.Now().In(zurich)
servedTime = whatTheClockShouldShow - clockOffset
```

For a clock configured as UTC+1:

| Season | Correct offset | Clock offset | DST correction | NTP serves | Clock displays      |
| ------ | -------------- | ------------ | -------------- | ---------- | ------------------- |
| CET    | UTC+1          | +1h          | 0              | UTC+0      | UTC+0+1h = correct  |
| CEST   | UTC+2          | +1h          | +1h            | UTC+1h     | UTC+1h+1h = correct |

The server detects CET↔CEST transitions using Go's `time.LoadLocation("Europe/Zurich")` and applies the correction immediately. Since the clock only syncs once per day (at midnight UTC), the new offset takes effect on the next sync.

## Implementation

The whole thing is a single Go package—no sub-packages, no internal directories. Five files:

- `main.go` — CLI flags, server startup, and a `-query` mode for testing
- `scheduler.go` — polls every 10 seconds, detects CET↔CEST transitions, sets the correction
- `source.go` — serves the faked time: UTC + NTP offset + DST correction + skew
- `server.go` — UDP NTP server, responds to queries with the faked time
- `ntp.go` — 48-byte SNTP packet marshal/unmarshal

The `-query` flag is handy for testing without an external NTP client:

```bash
./ntp-dst -query -query-host dst-ntp.n8r.ch -query-port 123
Time:      2026-05-23 10:15:00 UTC
Offset:    59m59.959s
Stratum:   2
Reference: 0x474F4C44
```

## Running as a Unikernel

Instead of running a container on a general-purpose OS, I'm running this as a [Nanos](https://nanos.org) unikernel via [OPS](https://ops.city). A unikernel is a single-purpose OS image—just my binary and a minimal kernel. No SSH, no shell, no package manager, no attack surface beyond what's strictly needed. For a single-purpose NTP server that needs to run 24/7 with zero maintenance, that's appealing:

- **No OS updates** — there's no OS to update
- **Fast boot** — milliseconds, not seconds
- **Minimal resources** — 128 MB RAM on OCI's free tier is plenty
- **Tiny image** — under 3 MB for the binary (timezone data embedded via `time/tzdata` import) and ~5.8 MB total as a qcow2 image including the Nanos kernel

### Build and test locally

```bash
# Build the static binary
make build

# Test locally on a high port (no root needed)
./ntp-dst -port 1234

# Query it from another terminal
./ntp-dst -query -query-port 1234
```

### Build the unikernel image

```bash
# x86_64
make build-unikernel
ops run -c ops.json ntp-dst

# ARM64 (Ampere A1 on OCI)
make build-unikernel-arm64
ops run -c ops.arm64.json ntp-dst-arm64
```

The `ops.json` config sets the CLI arguments, memory, and UDP ports:

```json
{
  "Args": ["-port", "123", "-ntp", "ch.pool.ntp.org", "-clock-offset", "1h"],
  "CloudConfig": {
    "BucketName": "<your-bucket>",
    "BucketNamespace": "<your-namespace>",
    "Flavor": "VM.Standard.E2.1.Micro"
  },
  "RunConfig": {
    "Memory": "128M",
    "UDPPorts": ["123"]
  },
  "ManifestPassthrough": {
    "exec_wait_for_ip4_secs": "5"
  }
}
```

Note: no CA certificates, no shared libraries, no `/usr/share/zoneinfo`. `CGO_ENABLED=0` gives us a pure-Go resolver, and the `_ "time/tzdata"` import embeds the timezone database directly in the binary. The only thing the unikernel needs from the outside is UDP port 123 and DNS resolution—both of which Nanos handles natively.

### Deploy to OCI

```bash
# x86_64
ops image create ntp-dst -t oci -c ops.json
ops instance create ntp-dst -t oci -c ops.json

# ARM64
ops image create ntp-dst-arm64 -t oci -c ops.arm64.json --arch=arm64
ops instance create ntp-dst-arm64 -t oci -c ops.arm64.json
```

Open UDP 123 in your OCI security list for the instance's VCN, and you're done.

## Why a Unikernel?

The unikernel model is a natural fit: you get a single-purpose image with no OS to maintain, and 128 MB RAM on OCI's free tier is plenty.

## DNS Configuration

The Mondaine clock has no setting for custom NTP servers—it hardcodes `time.pool.aliyun.com` as primary and `pool.ntp.org` as fallback. The trick is to override DNS on the router: create CNAME entries for both domains pointing to `dst-ntp.n8r.ch`, so the clock resolves them to the compensated server without knowing it.

Configure the clock's UTC offset to +1h (CET/winter time). The server handles the rest—the clock now shows the correct time year-round.

## Source

The code is on GitHub: [clementnuss/ntp-dst](https://github.com/clementnuss/ntp-dst).

