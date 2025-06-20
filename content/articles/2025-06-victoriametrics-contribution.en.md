---
title: "Adding PrometheusHistograms support to VictoriaMetrics/metrics"
date: 2025-06-18T07:57:54+02:00
slug: victoriametrics-metrics-prometheus-histogram-support
# cover:
#   image: /images/2024-kubenurse/kubenurse.png
tags: [golang, OSS, VictoriaMetrics, metrics, kubenurse, latency, histogram]

---


**TLDR**: I added support for PrometheusHistograms (those with `le` buckets) to
[VictoriaMetrics/metrics](https://github.com/VictoriaMetrics/metrics) package
(a lightweight alternative to
[prometheus/client_golang](https://github.com/prometheus/client_golang)), which
permits me to:

- switch to the more lightweight `VictoriaMetrics/metrics` library in my
Open-Source projects, which I find simpler to use
- make it possible to choose between classical Prometheus histograms or VictoriaMetrics
histograms (much more precise) at runtime

---

## Histograms

Before jumping

```text
╔═════════════════════════════════════════════════════════╗
║                    HISTOGRAM BUCKETS                    ║
╠═════════════════════════════════════════════════════════╣
║ Bucket    │ Count │ Requests in this bucket range       ║
║ (le=...)  │       │                                     ║
╠═══════════╪═══════╪═════════════════════════════════════╣
║ 0.1       │   1   │ 0.05s                               ║
║ 0.25      │   1   │ (no additional requests)            ║
║ 0.5       │   2   │ 0.3s                                ║
║ 1.0       │   3   │ 0.8s                                ║
║ 2.5       │   4   │ 1.2s                                ║
║ 5.0       │   5   │ 3.0s                                ║
║ 10.0      │   5   │ (no additional requests)            ║
║ +Inf      │   5   │ (no additional requests)            ║
╚═══════════╧═══════╧═════════════════════════════════════╝
```
