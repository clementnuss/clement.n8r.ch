---
title: "Minimal downtime when rebooting etcd nodes"
date: 2023-07-07T08:17:40+01:00
slug: minimal-downtime-when-rebooting-etcd-nodes
cover:
  image: /images/2023-etcd-leader-transition/etcd-logo.png
tags: [kubernetes, reboot, etcd, leader-election]
---

## Graceful leader changes

When needing to restart some Kubernetes control-plane nodes on which `etcd` also happens to be running, you will prefer a graceful transfer of the leadership of the `etcd` cluster, to reduce the transition period that comes with a leader election.

This can be achieved with the following script, provided you specify the adequate environment variables in `/etc/profile.d/etcd-all` file.

```bash
set -o pipefail && \
source /etc/profile.d/etcd-all && \
AM_LEADER=$(etcdctl endpoint status | grep $(hostname) | cut -d ',' -f 5 | tr -d ' ') && \
if [[ $AM_LEADER = "true" ]]
then
  NEW_LEADER=$(etcdctl endpoint status | grep -v $(hostname) | cut -d ',' -f 2 | tr -d ' ' | tail -n '-1') && \
  etcdctl move-leader $NEW_LEADER && sleep 15
fi
```

> Info: the following environment variables need to be set, for example through a file such as: `/etc/profile.d/etcd-all`

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS="https://node1.domain:2379,https://node2.domain:2379,https://node3.domain:2379"
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/peer.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/peer.key
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
```
