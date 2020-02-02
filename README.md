# Introduction
The administrator of a Kubernetes cluster wants to secure it against incoming traffic from outside the cluster. 
Calico is a Container Network Interface (CNI) plugin that, in addition to CNI capabilities, provides Network policies to control traffic between pods as well as firewall functionality to secure nodes. In order to utilize Calico's capabilities as a firewall to secure node using Calico's GlobalNetworkPolicy, a HostEndpoint would need to be created per network interface on the node. This is a one off job it could be automated within the installer. Since the nodes are ephemeral and policies can be dynamic, we need a way to manage HostEndpoint objects on each host even after installation.

There are several ways to accomplish this, for example,

1. Daemonset that runs a container on every node and installs needed artifacts
2. Static pod that runs on each node and installs needed artifacts
3. Kubernetes Operator that makes sure that HostEndpoint object is created all nodes in the cluster

We will use the first option using Daemonset. Unlike DaemonSet, static Pods cannot be managed with kubectl or 
other Kubernetes API clients. Daemonset ensures that a copy of a Pod always run on all or certain hosts, 
and it starts before other Pods.

# Solution
The proposed solution consists of creating a Daemonset that will launch a Pod per host. The Pod will run a container with script to install HostEndpoint object on that host, if required.

![Solution Overview](/images/ds.JPG)

