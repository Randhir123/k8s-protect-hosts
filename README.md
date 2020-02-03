# Introduction
The administrator of a Kubernetes cluster wants to secure it against incoming traffic from outside the cluster. 
Calico is a Container Network Interface (CNI) plugin that, in addition to CNI capabilities, provides Network policies to control traffic between pods as well as firewall functionality to secure nodes. In order to utilize Calico's capabilities as a firewall to secure node using Calico's GlobalNetworkPolicy, a HostEndpoint would need to be created per network interface on the node. This is a one off job it could be automated within the installer. Since the nodes are ephemeral and policies can be dynamic, we need a way to manage HostEndpoint objects on each host even after installation.

There are several ways to accomplish this using Kubernetes approach, for example,

1. DaemonSet that runs a container on every node and installs needed artifacts
2. Static pod that runs on each node and installs needed artifacts
3. Kubernetes Operator that makes sure that HostEndpoint object is created all nodes in the cluster

Outside of Kubernetes, traditional approaches to endpoint protection involves installing an agent on the host and enforcing policies through this agent.

We will use the first option using Daemonset. Unlike DaemonSet, static Pods cannot be managed with kubectl or 
other Kubernetes API clients. Daemonset ensures that a copy of a Pod always run on all or certain hosts, 
and it starts before other Pods.

# Solution Overview
The proposed solution consists of creating a DaemonSet that will launch a Pod per host. The Pod will run an application to create HostEndpoint object for that host, if required.

![Solution Overview](/images/ds.JPG)
 
As an example, we decide to enforce the following sample policy using HostEndpoint object:
- Allow any egress traffic from the nodes.
- Allow ingress SSH access to all nodes from a specific IP address.
- Deny any other traffic.

This results in the following sequence of steps:

1. Creating the application
2. Create a Docker image
3. Create a DaemonSet
4. Create Network policy 

## Creating the application
We will use shell script to write our application. The script loops infinitely and checks if a HostEndpoint object is created for the host where it is running. If not, it uses kubectl client to create HostEndpoint object for the host that is applicable for all the host's interfaces. If the HostEndpoint objects exists already for the host, it sleeps for 10 seconds before continuing. Notice that the name of the node is injected into the script via an environment variable. Node name is obtained using Downward API that allows containers to consume information about themselves or the cluster.
```
#!/bin/sh

while [ true ]; do

  echo $NODE_NAME

  kubectl get hostendpoint $NODE_NAME

  if [ $? -eq 0 ]; then
    echo "Found hep for node $NODE_NAME"
    sleep 10
    continue
  fi

  echo "Creating hep for node $NODE_NAME"

  kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: HostEndpoint
metadata:
  name: $NODE_NAME
  labels:
    host-endpoint: ingress
spec:
  interfaceName: "*"
  node: "$NODE_NAME"
EOF

done
```
The Network policy is applicable to any host that has label `host-endpoint`. We are creating the label here. The Network policies created later will check if the host has this label.

## Create a Docker image
To deploy your app to Kubernetes, we first have to containerise it. To do so, create the following Dockerfile in the same directory as the source code file:
```
FROM alpine

WORKDIR /app

ADD https://storage.googleapis.com/kubernetes-release/release/v1.17.0/bin/linux/amd64/kubectl /usr/local/bin

ADD run.sh /app

RUN chmod +x /usr/local/bin/kubectl
RUN chmod +x /app/run.sh
CMD [ "/app/run.sh" ]
```
We are using Alpine as our base image as it is a minimal Linux distribution that allows us to run a shell script. To talk to the Kubernetes API server, we include kubectl in the image and add the script created in the last step. When the container starts, script is executed.

Build the Docker image and push it to a Docker registry that is accessible from all the nodes in the Kubernetes cluster.
```
docker build -t randhirkumars/hepinstall:v1 .
docker push randhirkumars/hepinstall:v1
```
Needless to say, we need to login to the Docker registry if it requires credentials to push an image.

##  Create Network policy 
GlobalNetworkPolicy and HostEndpoint objects from Calico are available as custom objects. We need to create corresponding CustomResourceDefinition (CRD) first.
Create CRD for GlobalNetworkPolicy:
```
apiVersion: apiextensions.k8s.io/v1beta1
kind: CustomResourceDefinition
metadata:
  name: globalnetworkpolicies.crd.projectcalico.org
spec:
  scope: Cluster
  group: crd.projectcalico.org
  version: v1
  names:
    kind: GlobalNetworkPolicy
    plural: globalnetworkpolicies
    singular: globalnetworkpolicy
```
and CRD for HostEndpoint:
```
apiVersion: apiextensions.k8s.io/v1beta1
kind: CustomResourceDefinition
metadata:
  name: hostendpoints.crd.projectcalico.org
spec:
  scope: Cluster
  group: crd.projectcalico.org
  version: v1
  names:
    kind: HostEndpoint
    plural: hostendpoints
    singular: hostendpoint
```
```
kubectl create -f crds.yaml
```
Next create policies to
- Allow any egress traffic from the nodes.
```
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: allow-outbound-external
spec:
  order: 10
  egress:
    - action: Allow
  selector: has(host-endpoint)
```
- Allow ingress to all nodes from a specific IP address. Here, ingress traffic from CIDRs - [10.240.0.0/16, 192.168.0.0/16] are allowed.
```
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: allow-cluster-internal-ingress
spec:
  order: 10
  preDNAT: true
  applyOnForward: true
  ingress:
    - action: Allow
      source:
        nets: [10.240.0.0/16, 192.168.0.0/16]
  selector: has(host-endpoint)
```
- Deny any other traffic.
```
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: drop-other-ingress
spec:
  order: 20
  preDNAT: true
  applyOnForward: true
  ingress:
    - action: Deny
  selector: has(host-endpoint)
```
The order field is important here. The `drop-other-ingress` policy has a higher order value than `allow-cluster-internal-ingress`, so that it applies after `allow-cluster-internal-ingress`.
```
kubectl create -f policy.yaml
```

## Create a DaemonSet
Apart from the Docker image, to deploy our application on Kubernetes cluster, we need a few more artifacts.
- A Pod that runs the image in a container
- A Control plane object that watches over the Pod, DaemonSet in our case
- A service account with which Pod runs
- A cluster role that allows Pod to interact with API server for resources
- A cluster role binding to bind the cluster role to the service account

### Service Account
This is the service account that the Pod uses.
```
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hep-sa
```
### Cluster Role
We need RBAC to runs APIs on API server for HostEndpoint objects. We have asked for all actions on HostEndpoint objects from the appropriate API group. 
```
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: hep-cr
rules:
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - hostendpoints
    verbs:
      - create
      - get
      - list
      - update
      - watch
```
### Cluster role binding
Next, we need to bind the role to the service account thereby providing permissions to the Pod.
```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hep-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hep-cr
subjects:
- kind: ServiceAccount
  name: hep-sa
  namespace: default
```
### Pod and DaemonSet
Finally, create a DaemonSet object that will create a Pod with the desired service account. The host name is injected as an environment variable to the container. It is good practice to not run container with root privileges. Here, we are using a non-root account to run the container.
```
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hep-ds
  labels:
spec:
  selector:
    matchLabels:
      name: hep-ds
  template:
    metadata:
      labels:
        name: hep-ds
    spec:
      serviceAccountName: hep-sa
      containers:
      - image: randhirkumars/hepinstall:v1
        imagePullPolicy: Always
        name: hep-install
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          runAsUser: 1337
```

Create all the objects.
```
> kubectl apply -f hep.yaml
serviceaccount/hep-sa created
clusterrole.rbac.authorization.k8s.io/hep-cr created
clusterrolebinding.rbac.authorization.k8s.io/hep-crb created
daemonset.apps/hep-ds created

> kubectl get po
NAME                                     READY   STATUS    RESTARTS   AGE
hep-ds-9jjtq                             1/1     Running   0          2s
hep-ds-c97jz                             1/1     Running   0          2s
hep-ds-fbghm                             1/1     Running   0          2s
hep-ds-nbllb                             1/1     Running   0          2s
```
Check the logs for a Pod to ensure it is creating HostEndpoint for that node.
```
> kubectl logs hep-ds-9jjtq
k8s-node-2
Error from server (NotFound): hostendpoints.crd.projectcalico.org "k8s-node-2" not found
Creating hep for node k8s-node-2
hostendpoint.crd.projectcalico.org/k8s-node-2 created
k8s-node-2
NAME                    AGE
k8s-node-2   0s
Found hep for node k8s-node-2
k8s-node-2
NAME                    AGE
k8s-node-2   8s
Found hep for node k8s-node-2
```
Verify that HostEndpoint is created for each node.
```
> kubectl get hostendpoint
NAME                         AGE
k8s-master-nf-1   36s
k8s-master-nf-2   39s
k8s-master-nf-3   36s
k8s-node-1        38s
k8s-node-2        36s
```
## Test Network Policies
TBD
## Limitations
TBD
