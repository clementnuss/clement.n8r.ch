---
title: "Kubenurse: The In-Cluster Doctor Making Network Rounds"
date: 2024-04-07T12:12:16+00:00
slug: kubenurse-k8s-network-monitoring
cover:
  image: /images/2024-kubenurse/kubenurse.png
tags: [kubernetes, kubenurse, network monitoring, k8s, latency, histogram, CNI]

---

**TLDR**: Kubenurse is the Swiss army knife for Kubernetes network monitoring.

It will help you ..

* pinpoint bottlenecks and know the latency in your network
* identify nodes with network issues (packet drops, slow connection, etc.)
* uncover issues like DNS failures, broken sockets, or interrupted TLS
  negotiations

---

## Description

Kubenurse is a Kubernetes network monitoring tool developed and open-sourced by
PostFinance (as Swiss Banking Institution), which acts like an in-cluster
doctor, continuously checking the health of your pod-to-pod, pod-to-service,
and pod-to-ingress connections.

Kubenurse is a small Go application that runs as a `DaemonSet` on every node in
your cluster, and which continously performs requests against the following
endpoints:

1. **kubenurse ingress** endpoint itself, typically
   `https://kubenurse.your-cluster-ingress.yourdomain.tld` \
   &rarr; this endpoint lets us know about the end-to-end latency, and also
   permits to detect ingress controller problems
1. **kubenurse service** endpoint, i.e. `kubenurse.kubenurse.svc.cluster.local:8080` \
   &rarr; monitoring the service will be helpful in appreciating in-cluster
   network latency
1. **Kubernetes API server** through its **DNS** name,
   `kubernetes.default.svc.cluster.local` \
   &rarr; this endpoint captures both the K8s apiserver latency, as well as the
   DNS resolution inside the cluster.
1. **Kubernetes API server** - **direct** endpoint, e.g. `10.127.0.1` \
   &rarr; same as above, but bypassing DNS resolution. Interesting and helpful
   in conjunction with the above to quickly identify DNS lookup errors/slowness
1. **neighbouring kubenurse pods**, e.g. towards `node-02`, `node-03`, ... \
   especially helpful in diagnosing a neighbour with an erratic network
   connection.

## Metrics

For every one of these requests, instrumentation functions around Golang's http
client record information such as the overall latency of the request, the fact
that an error occurred during the request, and detailed information (time for
DNS lookup, time for TLS establishment, etc.) thanks to instrumentation with
Go [`http/httptrace`](https://pkg.go.dev/net/http/httptrace) package.

All this data is then available at the `/metrics` endpoint, and the following
metrics are exposed.

* `kubenurse_errors_total`: error counter partitioned by error type and request type
* `kubenurse_request_duration`: a histogram for kubenurse request duration partitioned by error type
* `kubenurse_httpclient_request_duration_seconds`:  a latency histogram of request latencies from the kubenurse http client.
* `kubenurse_httpclient_trace_requests_total`: a latency histogram for the http
  client _trace_ metric instrumentation, with detailed statistics for e.g.
  `dns_start`, `got_conn` events, and more. the details can be seen in the
  [`httptrace.go`](https://github.com/postfinance/kubenurse/blob/52767fbb280b65c06ac926dac49dd874e9ec4aee/internal/servicecheck/httptrace.go#L73)
  file

All of these metrics are partitioned with a `request_type` label, which permits
to compare the Kubernetes service latency with the ingress latency for example.

As the saying goes, *a picture is worth a thousand words*, so here we go, with a nice [excalidraw.com](https://excalidraw.com/) drawing to illustrate the different request types:

![kubenurse_request_types](/images/2024-kubenurse/kubenurse.png)

### Neighbouring nodes