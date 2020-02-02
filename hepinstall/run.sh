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
