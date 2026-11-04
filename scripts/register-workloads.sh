#!/usr/bin/env bash
set -euo pipefail

SERVER="kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server"
PARENT="spiffe://example.org/ns/spire/sa/spire-agent"

for wl in workload-a workload-b; do
  echo "Registering $wl..."
  $SERVER entry create \
    -parentID "$PARENT" \
    -spiffeID "spiffe://example.org/ns/default/sa/$wl" \
    -selector k8s:ns:default \
    -selector "k8s:sa:$wl" \
    -x509SVIDTTL 120
done
