---
title: "Kubernetes CNI — deconstructed"
date: 2021-03-29T05:42:38+01:00
slug: kubernetes-cni-deconstructed
tags: ["linux", "kubernetes", "networking", "containers", "kubernetes-networking"]
cover:
  image: /images/2021-cni-deconstructed/cni-deconstructed.png
aliases:
- /kubernetes-cni-deconstructed
---

A few months ago, I had to understand in detail how Container Network Interface (CNI) is implemented to, well, simply get a chaos testing solution working on a bare-metal installation of Kubernetes.

At that time, I found a few resources that helped me understand how this was implemented, mainly [Kubernetes' official documentation on the topic](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/), and the [official CNI specification](https://github.com/containernetworking/cni/blob/master/SPEC.md). And yes, this specification simply consists of a Markdown document, which I needed to invest a consequent amount of energy to digest and process.

I did not, however, find a step-by-step guide explaining how a CNI is practically working: is it running as a daemon? does it communicate on a socket? where are its configuration files?

**As it turned out, the answer to these 3 questions is not binary**: a typical CNI is both a binary and a daemon, communication happens over a socket and over another (unexpected, more on that later) channel, and its configuration files are stored in multiple locations!

## What is a CNI after all?

**A CNI is a Network Plugin**, installed and configured by the cluster
administrator. It **receives instructions from Kubernetes** to **set up the network interface(s) and IP address** for the pods.

It is quite important already to highlight that a CNI plugin is an executable, [as specified in the CNI specification](http://Each%20CNI%20plugin%20must%20be%20implemented%20as%20an%20executable%20that%20is%20invoked%20by%20the%20container%20management%20system%20%28e.g.%20rkt%20or%20Kubernetes%29.).

How does the CNI plugin know which interface type to configure, which IP address to set, etc? It receives instructions from Kubernetes and more specifically from the `kubelet` daemon running on the worker and master nodes, and these instructions are sent with/through:

* Environment variables: `CNI_COMMAND`, `CNI_NETNS`, `CNI_CONTAINERID`, and more commands. (exhaustive list [here](https://github.com/containernetworking/cni/blob/master/SPEC.md#parameters))

* `stdin`, in the form of a JSON file describing the network configuration for our container.

To better understand what happens when a new pod is created, I put together the following sequence diagram:

![CNI sequence diagram](/images/2021-cni-deconstructed/sequence-diagram.svg)

Sequence diagram highlighting the exchanges between the Container Runtime Interface (CRI) and the Container Networking Interface (CNI)

We have several steps happening:

1. `kubelet` sends a command ( `env` variables) and the network configuration (`json`) for a pod to the CNI executable

2. If the CNI executable is a simple CNI plugin (e.g. the `bridge` plugin), the configuration is directly applied to the pod network namespace (`netns`, I’ll explain that shortly)

3. If the CNI is more advanced (e.g. the Calico CNI), then the CNI executable will most probably contact its CNI daemon (through a socket call), where more advanced logic is happening. This “advanced” CNI daemon then configures the network interface for our pod.

### `netns` — network namespace?

Any idea how pods get their network interfaces and IP addresses? And how pods are isolated from the node (server) on which they run?

This is achieved through a Linux functionality called namespace: “**Linux Namespaces** are a feature of the [Linux kernel](https://en.wikipedia.org/wiki/Linux_kernel) that partitions kernel resources \[…\]”
Namespaces are extensively used when it comes to containerization, to partition the network of a Linux host, the process IDs, the mount paths, etc.
If you want to learn more about that, then [this article is a good read](https://medium.com/@saschagrunert/demystifying-containers-part-i-kernel-space-2c53d6979504)

In our case, we simply need to understand that a pod is associated with a network namespace (`netns`), and that the CNI, knowing this network namespace, can for example attach a network interface and configure IP addresses for our pod. It will do so with commands that will look like this:

{{< gist clementnuss 8f1903eb7e4086fc37adae74a1c3bb3b example_cni_attach.sh >}}

ℹ️ If you find this interesting, please note that working with the network namespace of your pod can greatly help you debug your networking problems: you will be able to execute any executable running on your host but restricted to the network namespace of your pod. Concretely, you could do:

```bash
nsenter -t $netns --network tcpdump -i any icmp
```

To only debug/intercept the traffic that your pod sees. You could even use this command if your pod doesn’t include the `tcpdump` executable. More info on this debugging technique [is in this article.](https://platform9.com/blog/container-namespaces-deep-dive-container-networking/)

## Down the rabbit hole: intercepting calls to a CNI plugin

Let's recapitulate, we know that:

* the CNI is an executable

* the CNI is called by `kubelet` (with the [Container Runtime Interface (CRI)](https://kubernetes.io/blog/2016/12/container-runtime-interface-cri-in-kubernetes/), e.g. `dockershim` , `podman`, etc., but let’s ignore that for our discussion)

* the CNI receives instructions through environment variables and a `json` file

If you have a CNI that doesn’t behave properly (I had an issue with Multus not correctly handling its sub-plugins, which I documented [here](https://github.com/k8snetworkplumbingwg/multus-cni/issues/544), for which [I submitted a fix that was merged in August 2020](https://github.com/k8snetworkplumbingwg/multus-cni/commit/4c271a57d5495198c3ba72f01e98b79cf033f3e5)), having the possibility to watch/intercept the exchanges between the Container Runtime (C**R**I) and the Network Plugin (C**N**I) will become extremely handy.

For that reason, I spent some time creating an interception script, that you can simply install in place of the real CNI executable. This script will intercept and log the environment variables, as well as the 3 standards file descriptors ( `stdin`, `stdout`, and `stderr` ), but this won’t prevent the real CNI from doing its job and attaching the correct network interfaces for our pods.
Concretely, to intercept calls to e.g. the `calico` CNI, you need to:

1. rename the real `calico` executable to `real_calico`
    This executable is most often located in the `/opt/cni/bin/` directory

2. save the following script as `/opt/cni/bin/calico` ( don’t forget to make the script executable 😉)

3. Go in the `/tmp/cni_logging` directory and watch as files are being created for all CRI/CNI exchanges 🔍

{{< gist clementnuss 104dfa85b1f18cedc61e7983dadb1691>}}

Once this is done, you will see many (depending on the number of pods) entries (tagged with the `cni` tag) in your journal, each corresponding to a CRI/CNI exchange. You can list them with `journalctl -t cni` :

![CNI Interceptor logs](/images/2021-cni-deconstructed/cni-interceptor-journalctl.png)

The screenshot on the left-hand side corresponds to all the exchanges that happened between the CRI and the CNI. Here we see pod `ADD`itions and `DEL`etions.

Your `/tmp/cni_logging/` directory will also be containing a lot of log files:

![CNI Interceptor - intercepted files](/images/2021-cni-deconstructed/cni-interceptor-logs.png)

For each CRI/CNI exchange, we indeed have the creation of 4 files:
`env`, `stdin`, `stdout`, and `stderr`.

Finally, for the curious reader that made it here 😜, an example output of our interceptor script can be seen [in this Github Gist](https://gist.github.com/clementnuss/6e2b58abd614a232f4ca1d35d405d64d) (not embed here, as it would otherwise make this story even longer).

Having a look at it, you see what happens when Kubernetes/Kubelet creates a pod:

1. The `CNI_COMMAND` environment variable is set to `ADD`, and the network namespace of the pod is sent through the `CNI_NETNS` environment variable

2. A JSON configuration file was sent through `stdin` specifies in which subnet to assign an IPv4 address, as well as other optional parameters (e.g. a port when using the `portMapping` functionality)

3. An answer (from the CNI), sent through `stdout`, containing the assigned IPv4 address as well as the name of the newly created network interface

We have up until now ignored the way Kubelet and the Container Runtime Interface choose which CNI is to be used. When the container runtime is Docker (and the CRI dockershim), the CRI scans the `/etc/cni/net.d/` folder, and chooses the first (in alphabetical order) `.conf` file (e.g. `00-multus.conf`). You can read more about this in the dockershim code: [K8s/dockershim/network/cni/cni.go::getDefaultCNINetwork](https://github.com/kubernetes/kubernetes/blob/2b9837fdcda0163712a439b71211e34a3f27bd34/pkg/kubelet/dockershim/network/cni/cni.go#L156)

You hopefully now have a concrete understanding of the way CNI (i.e. Network Plugins) are implemented and used within Kubernetes. If you have question or comments, please contact me, I’d be happy to clarify parts of this story.