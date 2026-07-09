---
title: "Kubenurse: The In-Cluster Doctor Making Network Rounds"
date: 2024-04-07T12:12:16+00:00
slug: kubenurse-k8s-network-monitoring
cover:
  image: /images/2024-kubenurse/kubenurse.png
tags: [kubernetes, kubenurse, network monitoring, k8s, latency, histogram, CNI]
aliases:
- /kubenurse

---

**TLDR**: [Kubenurse](https://github.com/postfinance/kubenurse) is the Swiss army knife for Kubernetes network monitoring.
It will help you

* pinpoint bottlenecks and know the latency in your network
* identify nodes with network issues (packet drops, slow connection, etc.)
* uncover issues like DNS failures, broken sockets, or interrupted TLS
  negotiations

---

## Description

[Kubenurse](https://github.com/postfinance/kubenurse) is a Kubernetes network monitoring tool developed and open-sourced by
PostFinance (a Swiss Banking Institution), which acts like an in-cluster
doctor, continuously checking the health of your pod-to-pod, pod-to-service,
and pod-to-ingress connections.

It is a small Go application that runs as a `DaemonSet` on every node in
your cluster, and which continously performs requests against the following
endpoints:

1. **kubenurse ingress** endpoint itself, typically
   `https://kubenurse.your-cluster-ingress.yourdomain.tld` \
   &rarr; this endpoint lets us know about the end-to-end latency, and also
   permits to detect ingress controller problems
1. **kubenurse service** endpoint, i.e. `kubenurse.kubenurse.svc.cluster.local:8080` \
   &rarr; monitoring the service will be helpful in appreciating in-cluster
   network latency
1. **Kubernetes API server / DNS**, through its DNS name,
   `kubernetes.default.svc.cluster.local` \
   &rarr; this endpoint captures both the K8s apiserver latency, as well as the
   DNS resolution inside the cluster.
1. **Kubernetes API server / IP**, through the direct endpoint, e.g. `10.127.0.1` \
   &rarr; same as above, but bypassing DNS resolution. Interesting and helpful
   in conjunction with the above to quickly identify DNS lookup errors/slowness
1. **neighbouring kubenurse pods**, e.g. towards `node-02`, `node-03`, ... \
   &rarr; especially helpful in diagnosing a neighbour with an erratic network
   connection.

It then collects error counters and detailed latency histograms, which can be
used for alerting and visualization. All the collected metrics are partitioned
with a `type` label, as can be seen in this
[excalidraw.com](https://excalidraw.com/) drawing which illustrates the
different request types.

![kubenurse_request_types](/images/2024-kubenurse/kubenurse.png)

---

## Metrics

For each request type, instrumentation functions around Golang's http client
record information such as the overall latency of the request, the fact that an
error occurred during the request, and detailed information (time for DNS
lookup, time for TLS establishment, etc.) thanks to instrumentation with Go
[`http/httptrace`](https://pkg.go.dev/net/http/httptrace) package.

All this data is then available at the `/metrics` endpoint, and the following
metrics are exposed.

| metric name                                           | labels               | description                                                                                                                  |
| ----------------------------------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `kubenurse httpclient request duration seconds`       | `type`               | latency histogram for request duration, partitioned by request type                                                          |
| `kubenurse httpclient trace request duration seconds` | `type, event`        | latency histogram for httpclient _trace_ metric instrumentation, partitioned by request type and httptrace connection events |
| `kubenurse httpclient requests total`                 | `type, code, method` | counter for the total number of http requests, partitioned by HTTP code, method, and request type                            |
| `kubenurse errors total`                              | `type, event`        | error counter, partitioned by httptrace event and request type                                                               |
| `kubenurse neighbourhood incoming checks`             | n\a                  | gauge which reports how many unique neighbours have queried the current pod in the last minute                               |

For metrics partitioned with a `type` label, it is possible to precisely know
which request type increased an error counter, or to compare the latencies of
multiple request types, for example compare how your service and ingress
latencies differ.

The `event` label takes value in e.g.  `dns_start`, `got_conn`,
`tls_handshake_done`, and more. the detailed label values can be  seen in the
[`httptrace.go`](https://github.com/postfinance/kubenurse/blob/v1.13.0/internal/servicecheck/httptrace.go#L91)
file.

---

## Getting started

Installing Kubenurse is a child's play with the provided Helm chart:

```shell
helm upgrade kubenurse --install \
  --repo=https://postfinance.github.io/kubenurse/ kubenurse \
  --set=ingress.url="kubenurse.yourdomain.tld"
```

Running that command should get you started, but you most likely need to
double-check your logs to make sure that you don't have any errors.

For the detailed configuration option, check the [Helm
parameters](https://github.com/postfinance/kubenurse/?tab=readme-ov-file#deployment)
collapsible section of the README, or the environment variable part if you
prefer to deploy with raw manifests.

---

## Grafana

Once everything is running and metrics are properly collected, you can import
the [example Grafana
dashboard](https://github.com/postfinance/kubenurse/blob/175c17cec93f373166a4df042d34085659df67c2/doc/grafana-kubenurse.json)
to start visualizing the metrics:

![kubenurse grafana overview](/images/2024-kubenurse/grafana.png)

---

## Neighbourhood check

{{< notice note >}}
This chapter is rather technical, you can skip to the [conclusion]({{< ref "2024-04-kubenurse.md#conclusion" >}}) if you are not
interested in knowing how hashing is used to randomly distribute the
neighbourhood checks.
{{< /notice >}}

As documented above, kubenurse conducts a series of `path_<neighbour-node-xx>`
checks against schedulable (i.e. non-cordoned) nodes, which permit to quickly
identify nodes with latency issues or connectivity problems.

### Neighbourhood filtering

While the neighbourhood check is really useful, without filtering, the number
of requests for the neighbourhood check in a cluster with \\( n \\) nodes was
growing as \\( O(n^2) \\), which rendered `kubenurse` impractical on large
clusters, as documented in issue
[#55](https://github.com/postfinance/kubenurse/issues/55).

To solve this issue, I recently implemented  a node filtering feature, which
works as follows

* Kubenurse computes its own node name checksum: `currentNodeHash`
* it then computes the `sha256` checksums for all neighbours' node names, and
  it computes `h := otherNodeHash - currentNodeHash`
* it puts the subtracted hash `h` in a size 10 max-heap, thereby keeping only
  the next 10 nodes to query.

If you want to take a look at the implementation for the node filtering, follow
over
[here](https://github.com/postfinance/kubenurse/blob/v1.13.0/internal/servicecheck/neighbours.go#L110-L138).

To make it more visual, here is an interactive visualization where you can play
with the number of nodes and neighbours. Feel free to adjust the sliders and
click on a node to see which neighbours it queries. Toggle between hash order
and linear order, or compare the filtered O(n) approach against the unfiltered
O(n²) one to appreciate the reduction in total checks.

{{< notice note >}}
This interactive visualization was added to the article in July 2026, ported
from my [KubeCon EU 2026 talk]({{< ref "2026-03-banking-on-reliability-kubecon.en.md" >}}).
{{< /notice >}}

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
    <button class="hr-toggle-btn hr-order-toggle" id="hr-all-on-btn">⊙ filtered <span class="hr-bigO">O(n)</span></button>
    <button class="hr-toggle-btn" id="hr-n2-btn">all <span class="hr-bigO">O(n²)</span></button>
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
.hr-bigO { font-family: 'Cambria Math', 'Latin Modern Math', Georgia, 'Times New Roman', serif; font-style: italic; font-size: 1.15em; letter-spacing: 0.5px; }
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
      this.innerHTML = showAllFiltered ? '✓ filtered <span class="hr-bigO">O(n)</span>' : '⊙ filtered <span class="hr-bigO">O(n)</span>';
      n2Btn.classList.remove('active');
      render();
    });

    n2Btn.addEventListener('click', function() {
      showAllToAll = !showAllToAll;
      if (showAllToAll) showAllFiltered = false;
      selectedNode = null;
      this.classList.toggle('active', showAllToAll);
      allOnBtn.classList.remove('active');
      allOnBtn.innerHTML = '⊙ filtered <span class="hr-bigO">O(n)</span>';
      render();
    });

    computeHashes(nodeCount);
  });
})();
</script>

Thanks to this filtering, every node is making queries to at most 10 nodes
(configurable) in its neighbourhood, unless one of the nodes is cordoned or
deleted, in which case the following node in the list is picked.

This filtering introduces many benefits:

* because of the way we first hash the node names, the checks are randomly
  distributed, independant of the node names. if we only picked the 10 next
  nodes in a sorted list of the node names, then we might have biased the
  results in environments where node names are sequential
* metrics-wise, a `kubenurse` pod should typically only have histogram entries
  for ca. 10 other neighbouring nodes worth of checks, which greatly reduces
  the load on your monitoring infrastructure
* because we use a deterministic algorithm to choose which nodes to query, the
  metrics churn rate stays minimal. (to the contrary, if we randomly picked 10
  nodes for every check, then in the end there would be one prometheus bucket
  for every node on the cluster, which would put useless load on the monitoring
  infrastructure)

Per default, the neighbourhood filtering is set to 10 nodes, which means that
on cluster with more than 10 nodes, each kubenurse will query exactly 10 nodes,
as described above.


---

## Conclusion

Kubenurse is a lightweight, easy-to-use, and powerful Kubernetes networking
monitoring tool that provides millisecond-level latency insights. By using
Kubenurse, you can

* troubleshoot network issues faster by pinpointing problems like ingress
  errors or DNS issues.
* set meaningul alerts and SLOs for your ingress latency, the apiserver
  latency, the node-to-node latency, etc.
* quickly identify broken nodes with flappy network links thanks to
  neighborhood checks.

Finally, PRs and issues are open, feel free to contribute or ask if
something is unclear or could be improved, I'll be happy to work on it :)
