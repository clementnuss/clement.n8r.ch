---
title: "Banking on Reliability: Cloud Native SRE Practices in Financial Services"
date: 2026-03-26T10:00:00+01:00
slug: banking-on-reliability-kubecon-eu-2026
cover:
  image: /images/2026/03-kubecon/k8s-slo-dashboard.png
tags: [kubernetes, sre, kubenurse, slo, "502", monitoring, e2e-testing, kubecon]
---

This article is a written companion to my [KubeCon EU 2026](https://events.linuxfoundation.org/kubecon-cloudnativecon-europe/) talk of the same name.
It covers four stories from five years of running a Kubernetes platform at
[PostFinance](https://www.postfinance.ch), a systemic Swiss financial institution:
SLOs as a reliability driver, open-source monitoring tools, continuous end-to-end
testing, and an interactive debugging session tracking down rare 502 errors.

The interactive visualizations below (hash ring, race condition sequence diagram)
are ported from the Slidev presentation so you can explore them at your own pace.

---

## Context

PostFinance operates ~35 Kubernetes clusters in an air-gapped environment with
strict regulatory requirements. The platform has been in production for 5+ years,
initially built on kubeadm/Debian and now undergoing a migration to
[Talos](https://www.siderolabs.com/platform/talos-os-for-kubernetes/) managed via
[TOPF](https://github.com/postfinance/topf/).

In banking, **every failed request is a potential denied payment**. This shapes
how we approach reliability — even single-digit errors out of millions matter.

---

## Part 1: SLOs as a Driver

### From "it feels slow" to data-driven reliability

For months, developers complained that "the cluster feels slow today." We had
basic Grafana dashboards, but no clear targets. Without a number and a timeline,
"slow" is subjective and easy to ignore.

### Defining API Server SLOs

We defined three SLOs for the Kubernetes API server (following the
[SRE book](https://sre.google/sre-book/service-level-objectives/) approach):

- **Availability** — less than 0.1% of requests return 5xx or 429
- **Latency (read)** — GET/LIST within threshold (varies by subresource & scope)
- **Latency (write)** — POST/PUT/PATCH/DELETE within 1s

Writing the PromQL queries by hand would have been tedious, but
[sloth](https://github.com/slok/sloth) made it tractable:

```yaml
slos:
  - name: apiserver-availability
    objective: 99.9
    sli:
      events:
        error_query: sum(apiserver_request_total{code=~"5..|429"})
        total_query: sum(apiserver_request_total)
```

From these definitions, sloth generates all recording rules, multi-window
burn-rate alerts, and error budget calculations automatically.

### SLOs Reveal the Truth

![Kubernetes SLO dashboard](/images/2026/03-kubecon/k8s-slo-dashboard.png)

Once SLOs were live, "the cluster feels slow" became "we burned 40% of our error
budget during Tuesday's upgrade." We were able to clearly correlate disruption
with some of our actions and this motivated us to improve the situation.

### Fix #1: etcd Topology

Our initial topology had each API server connecting to all 3 etcd members (a
variant of the
[external etcd topology](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/)).
When one etcd node was upgraded, all 3 API servers were impacted.

<div style="display: grid; grid-template-columns: 2fr 1fr; gap: 1rem; align-items: center;">
<div>

{{< excalidraw src="/images/2026/03-kubecon/etcd-initial-topology.excalidraw" >}}

</div>
<div>

![Complex junction road — our initial apiserver-etcd topology in a nutshell](/images/2026/03-kubecon/meme-complex-junction-road.jpg)

</div>
</div>

We switched to a **stacked topology**: each API server talks to its local etcd
only. An etcd upgrade now impacts only one API server instead of all three.
This improved the situation already, but we were still encountering degraded
apiserver availability during cluster maintenance, so we had to look further.

{{< excalidraw src="/images/2026/03-kubecon/etcd-stacked-topology.excalidraw" >}}

### Fix #2: etcd Leadership Migration

Before upgrading a node, we now migrate etcd leadership to another member:

```bash
etcdctl move-leader $NEW_LEADER_ID
```

This avoids leader elections during the maintenance window — a light improvement
but not the full solution.

<img src="/images/2026/03-kubecon/meme-etcd-leadership-hot-potato.jpg" alt="etcd leadership hot potato" style="max-width: 350px; display: block; margin: 1rem auto; border-radius: 8px;">

### Fix #3: The Real Culprit — `--goaway-chance`

The biggest issue was that one control-plane node was doing all the work while
the other two sat idle. Not only was the load poorly distributed, but more
critically the two other apiserver instances never had to populate their caches.
When the busy apiserver was shut down for maintenance, the remaining two would
choke while their caches were being filled from scratch.

The root cause: **long-lived HTTP/2 connections** never redistributed. Clients
open a TCP connection once and reuse it for all requests forever.

The fix: `--goaway-chance=0.001` on the API server. 1 in 1000 requests gets a
[GOAWAY frame](https://datatracker.ietf.org/doc/html/rfc7540#section-6.8),
causing the client to reconnect through the load balancer. Once all API servers
were handling traffic and had warm caches, upgrades stopped being a problem.

---

## Part 2: Open-Source Monitoring Tools

### kubenurse

[kubenurse](https://github.com/postfinance/kubenurse) is a DaemonSet that
performs continuous network health checks across your cluster. Each pod validates
5 different network paths from every node (see also my
[detailed kubenurse article]({{< ref "2024-04-kubenurse.en.md" >}})):

1. **API server (DNS)** — through `kubernetes.default.svc.cluster.local`
2. **API server (IP)** — direct endpoint, bypassing DNS
3. **me-ingress** — through the ingress controller
4. **me-service** — through the cluster service
5. **Neighbourhood** — node-to-node checks

{{< excalidraw src="/images/2026/03-kubecon/kubenurse-request-types.excalidraw" >}}

#### httptrace Instrumentation

Metrics are labeled with
[httptrace](https://pkg.go.dev/net/http/httptrace) event types, giving a precise
breakdown of each request phase: `dns_start`, `connect_done`,
`tls_handshake_done`, `got_first_response_byte`, etc. When something fails, you
know exactly *which phase* failed.

![kubenurse Grafana dashboard](/images/2026/03-kubecon/kubenurse-dashboard.png)

#### O(n²) → O(n): Deterministic Neighbor Selection

A [community discussion](https://github.com/postfinance/kubenurse/issues/55)
identified that the original design had every pod checking every other pod —
O(n²) total checks. The fix: node names are SHA-256 hashed and each pod checks
only its *n* nearest neighbors in hash order (default: n=10).

The distribution is random but deterministic — stable metrics across restarts.
Use the interactive visualization below to explore this:

<div class="hash-ring-widget-wrapper">
<div class="hash-ring-widget" id="hash-ring">
  <div class="hr-controls">
    <label>
      <span class="hr-label-text">Nodes: <strong id="hr-node-count-label">15</strong></span>
      <input type="range" min="5" max="30" value="15" id="hr-node-slider" />
    </label>
    <label>
      <span class="hr-label-text">Neighbors: <strong id="hr-neighbor-count-label">5</strong></span>
      <input type="range" min="1" max="14" value="5" id="hr-neighbor-slider" />
    </label>
    <button class="hr-toggle-btn hr-order-toggle active" id="hr-order-btn">🔀 hash order</button>
  </div>
  <div class="hr-controls">
    <button class="hr-toggle-btn hr-order-toggle" id="hr-all-on-btn">⊙ all O(n)</button>
    <button class="hr-toggle-btn" id="hr-n2-btn">O(n²)</button>
  </div>
  <svg viewBox="0 0 340 340" class="hr-ring-svg" id="hr-svg">
    <defs>
      <marker id="hr-arrowhead" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
        <polygon points="0 0, 8 3, 0 6" fill="#ff7f15" opacity="0.8" />
      </marker>
    </defs>
  </svg>
  <div class="hr-stats" id="hr-stats">
    Total checks: <strong id="hr-total">75</strong>
    <span class="hr-formula" id="hr-formula">(15 × 5)</span>
    <span class="hr-hint" id="hr-hint">click a node to see its neighbors</span>
  </div>
</div>
</div>

<style>
.hash-ring-widget-wrapper { display: flex; justify-content: center; margin: 2rem 0; }
.hash-ring-widget { display: flex; flex-direction: column; align-items: center; gap: 6px; font-family: 'Inter', system-ui, sans-serif; color: #333; width: 100%; }
.hr-controls { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; justify-content: center; }
.hr-controls label { display: flex; flex-direction: column; align-items: center; gap: 2px; }
.hr-label-text { font-size: 11px; color: #555; }
.hr-controls input[type="range"] { width: 90px; accent-color: #ff7f15; height: 4px; }
.hr-toggle-btn { font-size: 11px; padding: 4px 10px; border-radius: 12px; border: 1.5px solid #ff7f15; background: white; color: #ff7f15; cursor: pointer; font-weight: 600; transition: all 0.2s; }
.hr-toggle-btn.active { background: #dc2626; border-color: #dc2626; color: white; }
.hr-toggle-btn.hr-order-toggle.active { background: #ff7f15; border-color: #ff7f15; color: white; }
.hr-ring-svg { width: 100%; max-width: 600px; }
.hr-stats { font-size: 13px; color: #555; text-align: center; }
.hr-stats strong { color: #ff7f15; font-size: 15px; }
.hr-stats strong.red { color: #dc2626; }
.hr-formula { font-size: 11px; color: #999; margin-left: 4px; }
.hr-hint { font-size: 10px; color: #aaa; margin-left: 6px; }
</style>

<script>
(function() {
  const CX = 170, CY = 170, R = 140;
  let nodeCount = 15, neighborCount = 5, selectedNode = null;
  let showAllToAll = false, showAllFiltered = false, hashOrder = true;
  let hashCache = new Map();

  async function sha256_32(str) {
    const data = new TextEncoder().encode(str);
    const buf = await crypto.subtle.digest('SHA-256', data);
    return new DataView(buf).getUint32(0);
  }

  function nodeColor(idx, total) {
    return 'hsl(' + (idx / total) * 360 + ', 70%, 55%)';
  }

  async function computeHashes(count) {
    const map = new Map();
    for (let i = 0; i < count; i++) {
      const name = 'node-' + String(i + 1).padStart(2, '0');
      map.set(name, await sha256_32(name));
    }
    hashCache = map;
    render();
  }

  function getNodes() {
    if (hashCache.size < nodeCount) return [];
    const arr = [];
    for (let i = 0; i < nodeCount; i++) {
      const name = 'node-' + String(i + 1).padStart(2, '0');
      arr.push({ name: name, hash: hashCache.get(name), originalIndex: i });
    }
    arr.sort(function(a, b) { return a.hash - b.hash; });
    const withRing = arr.map(function(n, i) { return Object.assign({}, n, { ringIndex: i }); });
    return withRing.map(function(n) {
      const pos = hashOrder ? n.ringIndex : n.originalIndex;
      const angle = (pos / nodeCount) * 2 * Math.PI - Math.PI / 2;
      return Object.assign({}, n, {
        angle: angle,
        x: CX + R * Math.cos(angle),
        y: CY + R * Math.sin(angle),
        color: nodeColor(n.originalIndex, nodeCount)
      });
    });
  }

  function effectiveNeighbors() { return Math.min(neighborCount, nodeCount - 1); }

  function getNeighborIndices(ringIndex) {
    const indices = [];
    for (let j = 1; j <= effectiveNeighbors(); j++) {
      indices.push((ringIndex + j) % nodeCount);
    }
    return indices;
  }

  function shortenedLine(from, to, margin) {
    margin = margin || 12;
    const dx = to.x - from.x, dy = to.y - from.y;
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len < margin * 2) return { x1: from.x, y1: from.y, x2: to.x, y2: to.y };
    const ratio = (len - margin) / len;
    return { x1: from.x, y1: from.y, x2: from.x + dx * ratio, y2: from.y + dy * ratio };
  }

  function svgEl(tag, attrs) {
    const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const k in attrs) el.setAttribute(k, attrs[k]);
    return el;
  }

  function render() {
    const svg = document.getElementById('hr-svg');
    if (!svg) return;
    const nodes = getNodes();
    if (nodes.length === 0) return;
    // Clear all except defs
    const defs = svg.querySelector('defs');
    svg.innerHTML = '';
    svg.appendChild(defs);

    // Ring circle
    svg.appendChild(svgEl('circle', { cx: CX, cy: CY, r: R, fill: 'none', stroke: '#ddd', 'stroke-width': '1.5' }));

    // Tick marks
    for (let i = 0; i < 60; i++) {
      const a = (i / 60) * 2 * Math.PI;
      svg.appendChild(svgEl('line', {
        x1: CX + (R - 4) * Math.cos(a), y1: CY + (R - 4) * Math.sin(a),
        x2: CX + (R + 4) * Math.cos(a), y2: CY + (R + 4) * Math.sin(a),
        stroke: '#ccc', 'stroke-width': '0.5'
      }));
    }

    // O(n²) connections
    if (showAllToAll) {
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          svg.appendChild(svgEl('line', {
            x1: nodes[i].x, y1: nodes[i].y, x2: nodes[j].x, y2: nodes[j].y,
            stroke: '#dc2626', 'stroke-width': '0.8', opacity: '0.45'
          }));
        }
      }
    }

    // Neighbor connections
    if (!showAllToAll) {
      var conns = [];
      if (showAllFiltered) {
        for (let ri = 0; ri < nodes.length; ri++) {
          var indices = getNeighborIndices(ri);
          for (const idx of indices) conns.push({ from: nodes[ri], to: nodes[idx] });
        }
      } else if (selectedNode !== null && nodes[selectedNode]) {
        var sel = nodes[selectedNode];
        var indices = getNeighborIndices(selectedNode);
        for (const idx of indices) conns.push({ from: sel, to: nodes[idx] });
      }
      for (const c of conns) {
        const sl = shortenedLine(c.from, c.to);
        svg.appendChild(svgEl('line', {
          x1: sl.x1, y1: sl.y1, x2: sl.x2, y2: sl.y2,
          stroke: '#ff7f15', 'stroke-width': '1.5', opacity: '0.7',
          'marker-end': 'url(#hr-arrowhead)'
        }));
      }
    }

    // Nodes
    const neighborSet = new Set();
    if (selectedNode !== null) getNeighborIndices(selectedNode).forEach(function(i) { neighborSet.add(i); });

    for (const node of nodes) {
      const isSel = selectedNode === node.ringIndex;
      const isNeighbor = neighborSet.has(node.ringIndex);
      const isDimmed = showAllToAll;
      const r = isSel ? 13 : isNeighbor ? 11 : 10;
      const c = svgEl('circle', {
        cx: node.x, cy: node.y, r: r, fill: node.color,
        stroke: 'white', 'stroke-width': isSel ? '2.5' : '2',
        style: 'cursor:pointer;transition:cx 0.6s ease,cy 0.6s ease;' + (isDimmed ? 'opacity:0.5;filter:saturate(0.3);' : '')
      });
      c.addEventListener('click', (function(ri) {
        return function() { selectedNode = selectedNode === ri ? null : ri; render(); };
      })(node.ringIndex));
      svg.appendChild(c);

      const t = svgEl('text', {
        x: CX + (R + 24) * Math.cos(node.angle),
        y: CY + (R + 24) * Math.sin(node.angle),
        'text-anchor': 'middle', 'dominant-baseline': 'central',
        style: 'font-size:8px;fill:' + ((isSel || isNeighbor) ? '#333;font-weight:bold;font-size:9px;' : '#666;') +
          'pointer-events:none;user-select:none;transition:x 0.6s ease,y 0.6s ease;'
      });
      t.textContent = node.name.replace('node-', '');
      svg.appendChild(t);
    }

    // Stats
    const en = effectiveNeighbors();
    const total = showAllToAll ? nodeCount * (nodeCount - 1) : nodeCount * en;
    const totalEl = document.getElementById('hr-total');
    const formulaEl = document.getElementById('hr-formula');
    const hintEl = document.getElementById('hr-hint');
    if (totalEl) {
      totalEl.textContent = total;
      totalEl.className = showAllToAll ? 'red' : '';
    }
    if (formulaEl) formulaEl.textContent = '(' + nodeCount + ' × ' + (showAllToAll ? (nodeCount - 1) : en) + ')';
    if (hintEl) hintEl.textContent = (!showAllToAll && selectedNode === null) ? 'click a node to see its neighbors' : (!showAllToAll && selectedNode !== null) ? '← click a node' : '';
  }

  // Wire controls
  document.addEventListener('DOMContentLoaded', function() {
    var ns = document.getElementById('hr-node-slider');
    var nbs = document.getElementById('hr-neighbor-slider');
    var orderBtn = document.getElementById('hr-order-btn');
    var allOnBtn = document.getElementById('hr-all-on-btn');
    var n2Btn = document.getElementById('hr-n2-btn');

    if (!ns) return;

    ns.addEventListener('input', function() {
      nodeCount = parseInt(this.value);
      document.getElementById('hr-node-count-label').textContent = nodeCount;
      nbs.max = nodeCount - 1;
      if (neighborCount >= nodeCount) { neighborCount = nodeCount - 1; nbs.value = neighborCount; document.getElementById('hr-neighbor-count-label').textContent = neighborCount; }
      selectedNode = null;
      computeHashes(nodeCount);
    });

    nbs.addEventListener('input', function() {
      neighborCount = parseInt(this.value);
      document.getElementById('hr-neighbor-count-label').textContent = neighborCount;
      render();
    });

    orderBtn.addEventListener('click', function() {
      hashOrder = !hashOrder;
      this.textContent = hashOrder ? '🔀 hash order' : '🔢 linear order';
      this.classList.toggle('active', hashOrder);
      render();
    });

    allOnBtn.addEventListener('click', function() {
      showAllFiltered = !showAllFiltered;
      if (showAllFiltered) showAllToAll = false;
      selectedNode = null;
      this.classList.toggle('active', showAllFiltered);
      this.textContent = showAllFiltered ? '✓ all O(n)' : '⊙ all O(n)';
      n2Btn.classList.remove('active');
      render();
    });

    n2Btn.addEventListener('click', function() {
      showAllToAll = !showAllToAll;
      if (showAllToAll) showAllFiltered = false;
      selectedNode = null;
      this.classList.toggle('active', showAllToAll);
      allOnBtn.classList.remove('active');
      allOnBtn.textContent = '⊙ all O(n)';
      render();
    });

    computeHashes(nodeCount);
  });
})();
</script>

### hostlookuper

[hostlookuper](https://github.com/postfinance/hostlookuper) is simpler: it
periodically resolves DNS targets and exports latency + error counters as
Prometheus metrics. DNS is an excellent **network congestion indicator** — UDP
packets are not retried and result in errors, making DNS failures often the first
sign of trouble.

### Graceful Shutdown: Lameduck Mode

SLOs on kubenurse itself revealed errors on the `me_ingress` check during node
upgrades. The problem isn't specific to ingress-nginx: `SIGTERM` arrives, but
the load balancer doesn't know yet, so requests still route to a dying process.

The fix (inspired by CoreDNS): **lameduck shutdown**
([commit](https://github.com/postfinance/kubenurse/commit/cef5f2ef)).
On `SIGTERM`, keep serving for a few seconds (default: 5s), giving the LB/proxy/CNI
time to catch up and stop sending traffic. Then stop the server.

---

## Part 3: Continuous End-to-End Testing

### Your end users should NOT be your end-to-end tests

Complex interactions between Kubernetes components (networking, storage,
security, DNS) can fail in subtle ways that unit tests and CI pipelines don't
catch.

### Our Approach

A Go test suite using [e2e-framework](https://github.com/kubernetes-sigs/e2e-framework),
scheduled as a Kubernetes **CronJob** running every 15 minutes. Results are
captured with **OpenTelemetry** and visualized in Grafana dashboards.

```go
func TestKubernetesDeployment(t *testing.T) {
    start := time.Now()
    t.Cleanup(func() {
        metricsCollector.RecordTestExecution(t, time.Since(start))
    })

    dep := newDeployment("nginx", 3)
    err := env.Create(ctx, dep)
    require.NoError(t, err)

    waitForPodsReady(t, dep, 30*time.Second)
}
```

### Open-Source: e2e-tests

I've written an analogous open-source implementation at
[clementnuss/e2e-tests](https://github.com/clementnuss/e2e-tests) that you can
fork and adapt. It covers:

| Test | What it validates |
| --- | --- |
| **Deployment** | Pod scheduling, container runtime, workload lifecycle |
| **Storage (CSI)** | PV provisioning, read/write operations |
| **Networking** | DNS resolution, service discovery, inter-pod connectivity |
| **RBAC** | Role-based access boundaries, permission enforcement |

Deploy as a CronJob, stream metrics to an OTLP endpoint, and you get instant
cluster health monitoring with alert rules that trigger on test failures.

![e2e tests Grafana dashboard](/images/2026/03-kubecon/e2e-tests-dashboard.png)

---

## Part 4: The 502 Mystery

This section summarizes the investigation — for the full deep-dive, see my
[dedicated 502 article]({{< ref "2025-02-502-upstream-errors.en.md" >}}).

### The Symptoms

A Tomcat-based e-finance application serving ~1.7M requests/day on one ingress.
**8–10 failures per day** — roughly 6 per million. Observations:

- 502s uniformly distributed across all ingress-nginx pods
- No pattern in time, endpoint, or client
- App pods healthy, no errors in application logs
- Load testing with K6 couldn't reproduce it
- Errors correlate with request volume, but the **rate** stays constant

### The Breakthrough

ingress-nginx error logs contain the **FQDN**, not the ingress name. We were
searching for the wrong thing. Once we filtered by hostname, we found:

```text
upstream prematurely closed connection while reading response header from upstream
```

This told us: nginx had an open keepalive connection, sent a request on it, but
the backend closed the connection before responding → **502 Bad Gateway**.

### The Race Condition

Two conflicting keepalive timeouts:

- **nginx**: keeps connections open for **60s** (default)
- **Tomcat**: closes idle connections after **20s** (default)

The race window: the connection sits idle for ~20s, Tomcat sends a FIN to close
it, and at nearly the same moment nginx sends a new request on that connection.
The packets cross in flight → 502.

Explore the race condition with this interactive sequence diagram:

<div class="race-widget-wrapper">
<div class="race-widget" id="race-widget">
  <div class="rw-controls">
    <button class="rw-play-btn" id="rw-play-btn">▶</button>
    <button class="rw-play-btn" id="rw-replay-btn">↻</button>
    <input type="range" min="0" max="26" step="0.05" value="0" class="rw-scrubber" id="rw-scrubber" />
    <label class="rw-speed-label">
      <span><span id="rw-speed-label">1</span>x</span>
      <input type="range" min="0.25" max="3" step="0.25" value="1" class="rw-speed-slider" id="rw-speed-slider" />
    </label>
  </div>
  <svg viewBox="0 0 520 340" class="rw-race-svg" id="rw-svg"></svg>
</div>
</div>

<style>
.race-widget-wrapper { display: flex; justify-content: center; margin: 2rem 0; }
.race-widget { display: flex; flex-direction: column; align-items: center; gap: 4px; font-family: 'Inter', system-ui, sans-serif; width: 100%; }
.rw-controls { display: flex; align-items: center; gap: 8px; }
.rw-play-btn { width: 30px; height: 30px; border-radius: 50%; border: 1.5px solid #ff7f15; background: white; color: #ff7f15; font-size: 14px; cursor: pointer; display: flex; align-items: center; justify-content: center; font-weight: bold; transition: all 0.15s; }
.rw-play-btn:hover { background: #ff7f15; color: white; }
.rw-scrubber { width: 200px; accent-color: #ff7f15; height: 4px; }
.rw-speed-label { font-size: 10px; color: #888; display: flex; align-items: center; gap: 4px; }
.rw-speed-slider { width: 50px; accent-color: #ff7f15; height: 4px; }
.rw-race-svg { width: 100%; max-width: 700px; }
</style>

<script>
(function() {
  const W = 520, H = 340, NGINX_X = 100, TOMCAT_X = 420;
  const TIMELINE_Y = 60, TIMELINE_H = 240, MID_X = (NGINX_X + TOMCAT_X) / 2;
  const TOMCAT_TIMEOUT = 20, NGINX_TIMEOUT = 60, TOTAL_DURATION = 26;

  const REQUEST1_SEND = 0, REQUEST1_RECV = 0.8;
  const RESPONSE1_SEND = 1.2, RESPONSE1_RECV = 2.0;
  const TOMCAT_IDLE_START = 1.2, NGINX_IDLE_START = 2.0;
  const TOMCAT_FIN_SEND = TOMCAT_IDLE_START + TOMCAT_TIMEOUT;
  const NGINX_REQ2_SEND = 21.3, FIN_ARRIVE = 21.8, REQ2_ARRIVE = 21.9;
  const RST_SEND = 22.1, RST_ARRIVE = 22.7, SHOW_502 = 22.8;

  let time = 0, playing = false, speed = 1, animFrame = null, lastTs = null;

  function timeToY(t) { return TIMELINE_Y + (t / TOTAL_DURATION) * TIMELINE_H; }
  function packetProgress(sendTime, arriveTime) {
    if (time < sendTime) return -1;
    if (time > arriveTime) return 2;
    return (time - sendTime) / (arriveTime - sendTime);
  }
  function packetPos(fromX, toX, progress) {
    return fromX + (toX - fromX) * Math.max(0, Math.min(1, progress));
  }
  function clamp01(v) { return Math.max(0, Math.min(1, v)); }

  function svgEl(tag, attrs) {
    const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const k in attrs) el.setAttribute(k, attrs[k]);
    return el;
  }

  function render() {
    const svg = document.getElementById('rw-svg');
    if (!svg) return;
    svg.innerHTML = '';

    // Headers
    var t1 = svgEl('text', { x: NGINX_X, y: 28, 'text-anchor': 'middle', style: 'font-size:13px;font-weight:700;fill:#333;' });
    t1.textContent = 'ingress-nginx'; svg.appendChild(t1);
    var t1b = svgEl('text', { x: NGINX_X, y: 42, 'text-anchor': 'middle', style: 'font-size:10px;fill:#999;' });
    t1b.textContent = 'keepalive: 60s'; svg.appendChild(t1b);
    var t2 = svgEl('text', { x: TOMCAT_X, y: 28, 'text-anchor': 'middle', style: 'font-size:13px;font-weight:700;fill:#333;' });
    t2.textContent = 'Tomcat'; svg.appendChild(t2);
    var t2b = svgEl('text', { x: TOMCAT_X, y: 42, 'text-anchor': 'middle', style: 'font-size:10px;fill:#999;' });
    t2b.textContent = 'keepalive: 20s'; svg.appendChild(t2b);

    // Lifelines
    svg.appendChild(svgEl('line', { x1: NGINX_X, y1: TIMELINE_Y, x2: NGINX_X, y2: TIMELINE_Y + TIMELINE_H, stroke: '#bbb', 'stroke-width': '2', 'stroke-dasharray': '6 4' }));
    svg.appendChild(svgEl('line', { x1: TOMCAT_X, y1: TIMELINE_Y, x2: TOMCAT_X, y2: TIMELINE_Y + TIMELINE_H, stroke: '#bbb', 'stroke-width': '2', 'stroke-dasharray': '6 4' }));

    // Time cursor
    svg.appendChild(svgEl('line', { x1: NGINX_X - 30, y1: timeToY(time), x2: TOMCAT_X + 30, y2: timeToY(time), stroke: '#ff7f15', 'stroke-width': '1', opacity: '0.4', 'stroke-dasharray': '3 3' }));

    // Idle zone
    if (time >= TOMCAT_IDLE_START) {
      var idleEnd = Math.min(time, TOMCAT_IDLE_START + TOMCAT_TIMEOUT);
      svg.appendChild(svgEl('rect', {
        x: NGINX_X + 10, y: timeToY(TOMCAT_IDLE_START),
        width: TOMCAT_X - NGINX_X - 20,
        height: Math.max(0, timeToY(idleEnd) - timeToY(TOMCAT_IDLE_START)),
        fill: 'rgba(59,130,246,0.06)', stroke: 'rgba(59,130,246,0.15)', 'stroke-width': '1', rx: '4'
      }));
      var idleSec = Math.min(time - NGINX_IDLE_START, NGINX_TIMEOUT);
      if (time >= NGINX_IDLE_START) {
        var il = svgEl('text', { x: MID_X, y: timeToY(Math.min(NGINX_IDLE_START + 10, time)), 'text-anchor': 'middle', style: 'font-size:11px;fill:#6b7280;font-weight:500;' });
        il.textContent = 'idle: ' + Math.max(0, idleSec).toFixed(1) + 's'; svg.appendChild(il);
      }
    }

    // Tomcat timer bar
    if (time >= TOMCAT_IDLE_START) {
      var pct = Math.min(1, (time - TOMCAT_IDLE_START) / TOMCAT_TIMEOUT);
      var barH = pct * (timeToY(TOMCAT_IDLE_START + TOMCAT_TIMEOUT) - timeToY(TOMCAT_IDLE_START));
      var expired = time >= TOMCAT_IDLE_START + TOMCAT_TIMEOUT;
      svg.appendChild(svgEl('rect', {
        x: TOMCAT_X + 14, y: timeToY(TOMCAT_IDLE_START), width: 8, height: Math.max(0, barH),
        fill: expired ? '#dc2626' : '#3b82f6', opacity: '0.6', rx: '3'
      }));
      var remaining = TOMCAT_TIMEOUT - (time - TOMCAT_IDLE_START);
      if (remaining < 0) remaining = 0;
      var cd = svgEl('text', {
        x: TOMCAT_X + 30, y: timeToY(Math.min(time, TOMCAT_IDLE_START + TOMCAT_TIMEOUT)),
        style: 'font-size:10px;fill:' + (remaining < 2 ? '#dc2626' : '#3b82f6') + ';font-weight:700;font-variant-numeric:tabular-nums;'
      });
      cd.textContent = remaining.toFixed(1) + 's'; svg.appendChild(cd);
    }

    // Packet trails (static lines for completed packets)
    function trail(x1, y1, x2, y2, color, dash) {
      var attrs = { x1: x1, y1: y1, x2: x2, y2: y2, stroke: color, 'stroke-width': '1.5', opacity: '0.5' };
      if (dash) attrs['stroke-dasharray'] = '4 3';
      svg.appendChild(svgEl('line', attrs));
    }
    if (time >= REQUEST1_RECV) trail(NGINX_X, timeToY(REQUEST1_SEND), TOMCAT_X, timeToY(REQUEST1_RECV), '#ff7f15');
    if (time >= RESPONSE1_RECV) trail(TOMCAT_X, timeToY(RESPONSE1_SEND), NGINX_X, timeToY(RESPONSE1_RECV), '#22c55e');
    if (time >= TOMCAT_FIN_SEND) {
      var fp = packetProgress(TOMCAT_FIN_SEND, FIN_ARRIVE);
      trail(TOMCAT_X, timeToY(TOMCAT_FIN_SEND),
        packetPos(TOMCAT_X, NGINX_X, fp > 1 ? 1 : clamp01(fp)),
        timeToY(Math.min(time, FIN_ARRIVE)), '#dc2626', true);
    }
    if (time >= NGINX_REQ2_SEND) {
      var rp = packetProgress(NGINX_REQ2_SEND, REQ2_ARRIVE);
      trail(NGINX_X, timeToY(NGINX_REQ2_SEND),
        packetPos(NGINX_X, TOMCAT_X, rp > 1 ? 1 : clamp01(rp)),
        timeToY(Math.min(time, REQ2_ARRIVE)), '#ff7f15');
    }
    if (time >= RST_SEND) {
      var rstp = packetProgress(RST_SEND, RST_ARRIVE);
      trail(TOMCAT_X, timeToY(RST_SEND),
        packetPos(TOMCAT_X, NGINX_X, rstp > 1 ? 1 : clamp01(rstp)),
        timeToY(Math.min(time, RST_ARRIVE)), '#dc2626');
    }

    // Animated packets
    var packets = [];
    function addPkt(sendT, arriveT, fromX, toX, label, color) {
      var p = packetProgress(sendT, arriveT);
      if (p >= 0 && p <= 1) {
        packets.push({
          x: packetPos(fromX, toX, p),
          y: timeToY(sendT + p * (arriveT - sendT)),
          label: label, color: color
        });
      }
    }
    addPkt(REQUEST1_SEND, REQUEST1_RECV, NGINX_X, TOMCAT_X, 'GET /api', '#ff7f15');
    addPkt(RESPONSE1_SEND, RESPONSE1_RECV, TOMCAT_X, NGINX_X, '200 OK', '#22c55e');
    addPkt(TOMCAT_FIN_SEND, FIN_ARRIVE, TOMCAT_X, NGINX_X, 'FIN', '#dc2626');
    addPkt(NGINX_REQ2_SEND, REQ2_ARRIVE, NGINX_X, TOMCAT_X, 'GET /api', '#ff7f15');
    addPkt(RST_SEND, RST_ARRIVE, TOMCAT_X, NGINX_X, 'RST', '#dc2626');

    for (const pkt of packets) {
      svg.appendChild(svgEl('circle', { cx: pkt.x, cy: pkt.y, r: 5, fill: pkt.color, style: 'filter:drop-shadow(0 0 3px rgba(0,0,0,0.2));' }));
      var pl = svgEl('text', { x: pkt.x, y: pkt.y - 9, 'text-anchor': 'middle', fill: pkt.color, style: 'font-size:9px;font-weight:700;' });
      pl.textContent = pkt.label; svg.appendChild(pl);
    }

    // 502 explosion
    if (time >= SHOW_502) {
      svg.appendChild(svgEl('rect', { x: NGINX_X - 58, y: timeToY(SHOW_502) - 14, width: 116, height: 28, rx: 6, fill: '#dc2626' }));
      var lbl = svgEl('text', { x: NGINX_X, y: timeToY(SHOW_502) + 5, 'text-anchor': 'middle', style: 'fill:white;font-size:13px;font-weight:800;' });
      lbl.textContent = '502 Bad Gateway'; svg.appendChild(lbl);
    }

    // Status text
    var nginxStatus = time < REQUEST1_SEND ? 'idle' : time < RESPONSE1_RECV ? 'waiting...' : time < NGINX_REQ2_SEND ? 'keepalive' : time < SHOW_502 ? 'sending req #2' : '502 !';
    var tomcatStatus = time < REQUEST1_RECV ? 'listening' : time < RESPONSE1_SEND ? 'processing' : time < TOMCAT_FIN_SEND ? 'keepalive' : time < RST_SEND ? 'closing...' : 'closed';
    var ns = svgEl('text', { x: NGINX_X, y: TIMELINE_Y + TIMELINE_H + 18, 'text-anchor': 'middle', style: 'font-size:11px;fill:#666;font-weight:500;' });
    ns.textContent = nginxStatus; svg.appendChild(ns);
    var ts = svgEl('text', { x: TOMCAT_X, y: TIMELINE_Y + TIMELINE_H + 18, 'text-anchor': 'middle', style: 'font-size:11px;fill:#666;font-weight:500;' });
    ts.textContent = tomcatStatus; svg.appendChild(ts);

    // Update scrubber
    var scrubber = document.getElementById('rw-scrubber');
    if (scrubber && playing) scrubber.value = time;
  }

  function tick(ts) {
    if (!playing) { lastTs = null; return; }
    if (lastTs !== null) {
      var dt = (ts - lastTs) / 1000 * speed;
      time = Math.min(time + dt, TOTAL_DURATION);
      if (time >= TOTAL_DURATION) playing = false;
    }
    lastTs = ts;
    render();
    if (playing) animFrame = requestAnimationFrame(tick);
  }

  function play() {
    if (time >= TOTAL_DURATION) time = 0;
    playing = true; lastTs = null;
    var btn = document.getElementById('rw-play-btn');
    if (btn) btn.textContent = '⏸';
    animFrame = requestAnimationFrame(tick);
  }

  function pause() {
    playing = false;
    var btn = document.getElementById('rw-play-btn');
    if (btn) btn.textContent = '▶';
  }

  document.addEventListener('DOMContentLoaded', function() {
    var playBtn = document.getElementById('rw-play-btn');
    var replayBtn = document.getElementById('rw-replay-btn');
    var scrubber = document.getElementById('rw-scrubber');
    var speedSlider = document.getElementById('rw-speed-slider');

    if (!playBtn) return;

    playBtn.addEventListener('click', function() { playing ? pause() : play(); });
    replayBtn.addEventListener('click', function() { time = 0; play(); });
    scrubber.addEventListener('input', function() { pause(); time = parseFloat(this.value); render(); });
    speedSlider.addEventListener('input', function() {
      speed = parseFloat(this.value);
      document.getElementById('rw-speed-label').textContent = speed;
    });

    render();
  });
})();
</script>

### The Fix

One environment variable:

```bash
export TC_HTTP_KEEPALIVETIMEOUT="75000"  # 75s > nginx's 60s
```

**The rule:** the upstream `keepalive_timeout` must be **greater** than the
reverse proxy's. nginx defaults to 60s; Tomcat was at 20s, now set to 75s. The
backend always outlives the proxy's connection → no more race.

### Reproducing with K6

Standard load tests failed because they didn't test **idle + burst** patterns.
The key insight: cycle through load → idle → load phases with varying idle
durations to hit the keepalive race window:

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

// Cycle: ramp up → sustain → ramp down → idle
// Idle duration increases (4s→11s) to maximize
// chance of hitting Tomcat's 20s timeout boundary
function generate_stages() {
    var stages = []
    for (let i = 4; i < 12; i++) {
        stages.push({ duration: "5s", target: 100 });
        stages.push({ duration: "55s", target: 100 });
        stages.push({ duration: "5s", target: 0 });
        stages.push({ duration: i + "s", target: 0 });
    }
    return stages
}

export let options = {
    noConnectionReuse: true,
    noVUConnectionReuse: true,
    scenarios: {
        http_502: {
            stages: generate_stages(),
            executor: 'ramping-vus',
            gracefulRampDown: '1s',
        },
    },
};

export default function() {
    let data = { data: 'Hello World' };
    for (let i = 0; i < 10; i++) {
        let res = http.post(
          `${__ENV.URL}`, JSON.stringify(data));
        check(res, {
          "status was 200": (r) => r.status === 200
        });
    }
    sleep(1);
}
```

---

## Key Takeaways

- **SLOs are a forcing function** — from "it feels slow" to data-driven fixes
  (etcd topology, leadership migration, goaway-chance)
- **Open-source your tools** — the best fixes come from community discussions,
  not always code, sometimes just the right conversation
  ([kubenurse #55](https://github.com/postfinance/kubenurse/issues/55))
- **Test continuously, in-cluster** — your end users should not be your e2e tests
- **Every error matters** — 8 out of 1.7M requests still deserved investigation

---

## Links

- [kubenurse](https://github.com/postfinance/kubenurse) — network monitoring DaemonSet
- [hostlookuper](https://github.com/postfinance/hostlookuper) — DNS monitoring
- [TOPF](https://github.com/postfinance/topf/) — Talos fleet management
- [e2e-tests](https://github.com/clementnuss/e2e-tests) — K8s cluster validation CronJob
- [sloth](https://github.com/slok/sloth) — SLO-to-recording-rules generator
- [502 upstream errors — full article]({{< ref "2025-02-502-upstream-errors.en.md" >}})
- [kubenurse — detailed article]({{< ref "2024-04-kubenurse.en.md" >}})
