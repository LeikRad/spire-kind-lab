d# spire-kind-lab

SPIRE running on a local kind cluster, issuing SPIFFE identities to two workloads. I made it to understand workload identity: how a pod gets a certificate without being given any secret, and what that certificate actually proves.
Once both workloads had their identities, I broke it on purpose: revoked an identity, tried to impersonate a workload, and killed the agent.

This builds on [mini-ca-mtls](https://github.com/LeikRad/mini-ca-mtls), where I did the same kind of PKI by hand.

## What's in here

| Path                                        | What it is                                                                                    |
| ------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `kind-config.yaml`                          | kind cluster with one control-plane node and one worker.                                      |
| `manifests/`                                | SPIRE server and agent (`kubectl apply -k`), plus `workload-a.yaml` and `workload-b.yaml`.    |
| `scripts/create-node-registration-entry.sh` | Registers the node alias that every agent in the cluster gets.                                |
| `scripts/register-workloads.sh`             | Registers `workload-a` and `workload-b` with a 120 second SVID TTL.                           |
| `notes/`                                    | Output captured during the experiments below: entries, SVIDs, rotation logs, failures.        |

The SPIRE manifests and the node registration script are adapted from the Kubernetes quickstart in [spiffe/spire-tutorials](https://github.com/spiffe/spire-tutorials) (Apache-2.0). I bumped the workload image from 1.5.1 to 1.11.2 to match the server and agent.

## Run it

Needs Docker, kind, kubectl, jq and openssl.

```sh
kind create cluster --config kind-config.yaml
kubectl apply -k manifests/

kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server healthcheck
bash scripts/create-node-registration-entry.sh
bash scripts/register-workloads.sh

kubectl apply -f manifests/workload-a.yaml -f manifests/workload-b.yaml
kubectl logs -f deploy/workload-a
```

`register-workloads.sh` is not idempotent. Running it twice fails on the first entry that already exists.

## How a pod gets an identity

There are two attestation steps, and the pod takes part in neither of them.

**Node attestation.** The agent runs as a DaemonSet. On startup it sends the server its projected service account token (`k8s_psat`). The server asks the Kubernetes API whether the token is real and only accepts agents running as `spire:spire-agent` in `demo-cluster`. The agent gets an ID that ends in the node's UID:

```
spiffe://example.org/spire/agent/k8s_psat/demo-cluster/0e19944a-abf3-4f3e-934f-8cf824666013
```

**Workload attestation.** When a pod connects to the agent's Unix socket, the agent sees the caller's PID, asks the kubelet which pod it belongs to, and turns the answer into selectors like `k8s:ns:default` and `k8s:sa:workload-a`. If a registration entry matches all of them, the agent issues that entry's SPIFFE ID.

The entries form a tree. The node alias gives workload entries a stable parent, so they don't depend on a node UID that changes whenever the node is recreated.

```
spiffe://example.org/spire/server
└── ns/spire/sa/spire-agent          node alias, k8s_psat selectors
    ├── ns/default/sa/workload-a     k8s:ns:default + k8s:sa:workload-a, TTL 120s
    └── ns/default/sa/workload-b     k8s:ns:default + k8s:sa:workload-b, TTL 120s
```

The entries exist before any pod does. They are rules waiting for a pod to match them. Full output is in `notes/02-entries.txt`.

## Looking at an SVID

The spire-agent image has no `cat`, so `fetch x509 -write` plus copying the files out doesn't work however JSON output does:

```sh
kubectl exec deploy/workload-a -- /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock -output json \
  | jq -r '.svids[0].x509_svid' | base64 -d \
  | openssl x509 -inform DER -out notes/workload-a-svid.pem
```

```
Issuer: C=US, O=SPIFFE, serialNumber=11827741822603966227127604124622101540
Validity
    Not Before: Nov  4 01:50:07 2026 GMT
    Not After : Nov  4 01:52:17 2026 GMT
Subject: C=US, O=SPIRE
Public Key Algorithm: id-ecPublicKey (P-256)
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment, Key Agreement
X509v3 Extended Key Usage:
    TLS Web Server Authentication, TLS Web Client Authentication
X509v3 Basic Constraints: critical
    CA:FALSE
X509v3 Authority Key Identifier:
    93:6F:D0:CB:51:9C:AD:A6:61:18:C2:E3:5A:D3:AD:C5:91:79:B2:D7
X509v3 Subject Alternative Name:
    URI:spiffe://example.org/ns/default/sa/workload-a
```

Compared to the certs in mini-ca-mtls:

- The identity is the `URI` in the SAN. The subject is `C=US, O=SPIRE` for every workload and nothing looks at it.
- One cert has both `serverAuth` and `clientAuth`. In mini-ca-mtls the server and client certs were separate profiles. Here any workload can be on either side of a connection.
- The validity is 2m10s, not the 120s I asked for. SPIRE backdates `Not Before` by 10 seconds to allow for clock skew.
- The workload key is EC P-256, signed by SPIRE's RSA CA key. They don't have to match.

The bundle is the trust root, the equivalent of `ca.crt` in mini-ca-mtls. Its subject is the SVID's issuer and its Subject Key Identifier is `93:6F:D0:CB:...`, the same as the SVID's Authority Key Identifier.

```sh
openssl verify -CAfile notes/bundle.pem notes/workload-a-svid.pem
openssl verify -no_check_time -CAfile notes/bundle.pem notes/workload-a-svid.pem
```

```
error 10 at 0 depth lookup: certificate has expired
error notes/workload-a-svid.pem: verification failed
notes/workload-a-svid.pem: OK
```

I didn't break anything to get the first error. I saved the SVID at 01:50 and verified it about three minutes later, by which point it had expired. The signature is fine (`-no_check_time` gives `OK`). A copied SVID stops working on its own within minutes.

## Rotation

The workload pods run `spire-agent api watch`, which prints every SVID the agent pushes to them. Over about six minutes `workload-a` got seven:

| Valid after | Valid until | Received after previous |
| ----------- | ----------- | ----------------------- |
| 01:48:17    | 01:50:27    | (first)                 |
| 01:49:16    | 01:51:26    | 13s                     |
| 01:50:07    | 01:52:17    | 50s                     |
| 01:51:08    | 01:53:18    | 62s                     |
| 01:52:08    | 01:54:18    | 60s                     |
| 01:53:04    | 01:55:14    | 55s                     |
| 01:54:03    | 01:56:13    | 60s                     |

The agent renews at roughly half the lifetime, so each new cert arrives about 70 seconds before the old one expires. The workload never goes without a valid cert, and it never restarts or reloads anything. New certs just arrive on the open stream.

The first SVID was valid from 01:48:17, but the pod only started around 01:49:03. The agent most likely minted it as soon as the entry was registered, before any pod asked for it, so it was already halfway through its life when the workload received it.

Full log in `notes/03-rotation-workload-a.txt`.

## Breaking it

| #   | What I did                                         | What happened                                                                      |
| --- | -------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 1   | Deleted `workload-b`'s entry                       | `PermissionDenied: no identity issued` within seconds. Its last cert stayed valid. |
| 2   | Re-created the entry                               | The same running pod got its identity back. No restart.                            |
| 3   | Same ServiceAccount name, different namespace      | `no identity issued`. The namespace selector didn't match.                         |
| 4   | Deleted the agent pod                              | The workload lost the socket for ~17s, then reconnected and got a new SVID.        |

### 1. Revoking an identity

```sh
kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server entry delete -entryID <workload-b entry>
```

```
SVID Valid After:       2026-11-04 01:55:41 +0000 UTC
SVID Valid Until:       2026-11-04 01:57:51 +0000 UTC

rpc error: code = PermissionDenied desc = no identity issued
rpc error: code = PermissionDenied desc = no identity issued
```

On its next sync with the server the agent dropped the entry and told the workload straight away. But the cert the workload already had was valid until 01:57:51, and nothing can take that back. There is no CRL or OCSP. Revoking means the agent stops renewing, and the TTL limits how long a cert that's already out there keeps working. With my 120s TTL that's about two minutes. With SPIRE's default of one hour, it would be up to an hour.

Log in `notes/05-revoke-workload-b.txt`.

### 2. Restoring it

I re-created the entry with the same SPIFFE ID and selectors, and left the pod alone.

```
rpc error: code = PermissionDenied desc = no identity issued
Received 1 svid after 1m10.976048795s

SPIFFE ID:              spiffe://example.org/ns/default/sa/workload-b
SVID Valid After:       2026-11-04 01:56:51 +0000 UTC
```

Access is controlled entirely from the server. The workload never needed a redeploy or a config change, either to lose its identity or to get it back.

### 3. Impersonating workload-a

```sh
kubectl create namespace attacker
sed 's/namespace: default/namespace: attacker/' manifests/workload-a.yaml | kubectl apply -f -
```

This pod is a copy of `workload-a` in every way I could control: same ServiceAccount name, same labels, same image, same socket, same node, same agent. Only the namespace is different.

```
rpc error: code = PermissionDenied desc = no identity issued
```

The pod never says who it is. The kubelet reports the facts it knows because it created the pod, `ns:attacker` and `sa:workload-a`. The entry needs `ns:default` and `sa:workload-a`, and every selector has to match. An attacker can pick any names they want but can't change what the kubelet reports.

If the entry had only `k8s:sa:workload-a`, this would have worked. Entries need enough selectors to pin down a workload.

Log in `notes/07-impersonation-denied.txt`.

### 4. Killing the agent

```sh
kubectl delete pod -n spire -l app=spire-agent
```

```
rpc error: code = Unavailable desc = error reading from server: EOF
rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial unix /run/spire/sockets/agent.sock: connect: no such file or directory"
Received 1 svid after 16.708134009s

SPIFFE ID:              spiffe://example.org/ns/default/sa/workload-a
SVID Valid After:       2026-11-04 02:00:48 +0000 UTC
```

The open stream closed (`EOF`), then the socket was gone until the DaemonSet started a new agent. About 17 seconds later the new agent had attested again and the workload reconnected by itself.

The agent came back with the same SPIFFE ID but a new cert:

|               | Before                   | After restart            |
| ------------- | ------------------------ | ------------------------ |
| SPIFFE ID     | `.../demo-cluster/0e19…` | `.../demo-cluster/0e19…` |
| Serial number | `156250746537…`          | `110146470362…`          |
| Expires       | 02:31:57                 | 03:00:58                 |

The ID belongs to the node, not the pod. The old agent's key only existed in memory, and the new one proved itself from scratch with a fresh Kubernetes token. Nothing was stored on disk.

Agent lists in `notes/01-agent-list.txt` and `notes/09-agent-list-after-restart.txt`.

## Tradeoffs and limits

- **TTL is a tradeoff.** A short TTL limits how long a leaked or revoked cert works (experiment 1). A long TTL lets workloads survive longer agent outages, because a workload is fine as long as the agent is back before its current cert expires (experiment 4). With 120s that's about a minute of tolerance.
- **Kubernetes RBAC is part of the trust boundary.** Selectors stop naming tricks, but anyone who can create pods in `default` running as `workload-a` gets that identity legitimately.
- **`skip_kubelet_verification = true`.** The agent doesn't verify the kubelet's TLS cert, because kind doesn't give it one the cluster CA can check. Fine for a lab, not for production.
- **The workloads run with `hostPID` and `hostNetwork`**, copied from the quickstart client. The agent is the one that looks up PIDs, so the workloads probably don't need either. I haven't tested removing them yet.
- **Trust domain is `example.org`.** It's the quickstart default.
