# In-Cluster Access to MaaS Models

How to consume MaaS-governed models from workloads running inside the same OpenShift cluster without going through the external Route.

Applies to: RHOAI 3.4 GA, GatewayClass `data-science-gateway-class`.

## Problem

The default MaaS access path routes traffic externally:

```
Agent Pod -> Route (external DNS) -> Load Balancer -> Gateway (Envoy) -> AuthPolicy -> Model Pod
```

For in-cluster agents this adds unnecessary latency: traffic exits the cluster, hits the external load balancer, re-enters, and traverses TLS termination twice.

## Solution: Use the Gateway's Internal ClusterIP

When OpenShift creates a Gateway, the Gateway controller also creates a backing Kubernetes Service with a ClusterIP in the same namespace. This Service is reachable from any pod inside the cluster.

```
Agent Pod -> Gateway Service (ClusterIP) -> AuthPolicy -> Model Pod
```

### Internal Service Details

| Resource | Name | Namespace | Port |
| --- | --- | --- | --- |
| Gateway Service | `maas-default-gateway-data-science-gateway-class` | `openshift-ingress` | 443 (HTTPS) |
| Direct model Service | `<model>-kserve-workload-svc` | model namespace | 8000 (HTTPS) |

The Gateway Service name follows the pattern `<gateway-name>-<gatewayclass-name>`. Since we use `maas-default-gateway` with class `data-science-gateway-class`, the Service is `maas-default-gateway-data-science-gateway-class`.

Verify in your cluster:

```bash
oc get svc -n openshift-ingress | grep maas
```

### SNI Requirement (hostname listener)

When the Gateway listener has a `hostname` configured (e.g., `maas.apps.cluster.example.com`), Envoy filters incoming TLS connections by SNI (Server Name Indication). The ClusterIP service's internal DNS (`*.svc.cluster.local`) does **not** match the hostname, so a bare `curl` to the ClusterIP will fail with `SSL_ERROR_SYSCALL`.

The solution is `curl --resolve`, which sends the correct SNI hostname while routing to the ClusterIP address:

```bash
GATEWAY_SVC="maas-default-gateway-data-science-gateway-class"
GATEWAY_NS="openshift-ingress"
GATEWAY_HOST="maas.apps.cluster.example.com"  # from: oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}'

# Resolve the ClusterIP
CLUSTER_IP=$(getent hosts ${GATEWAY_SVC}.${GATEWAY_NS}.svc.cluster.local | awk '{print $1}')

# Use --resolve to map the external hostname to the ClusterIP
curl -sk "https://${GATEWAY_HOST}/models-as-a-service/tinyllama-test/v1/chat/completions" \
  --resolve "${GATEWAY_HOST}:443:${CLUSTER_IP}" \
  -H "Authorization: Bearer sk-oai-..." \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama-test","messages":[{"role":"user","content":"Hi"}],"max_tokens":50}'
```

Without `--resolve`, the hostname resolves via external DNS, traffic exits the cluster, and you lose the latency benefit.

## Authentication: API Keys (not OCP tokens)

RHOAI 3.4 GA uses API keys (`sk-oai-*`) for inference, not OCP/MaaS tokens. OCP tokens are only accepted for `/v1/models` (model listing). The API key flow is:

### Step 1: Create an API key

Use an OCP token to create an API key via maas-api:

```bash
GATEWAY_HOST="maas.apps.cluster.example.com"
CLUSTER_IP=$(getent hosts maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local | awk '{print $1}')
OCP_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

API_KEY=$(curl -sk -X POST "https://${GATEWAY_HOST}/maas-api/v1/api-keys" \
  --resolve "${GATEWAY_HOST}:443:${CLUSTER_IP}" \
  -H "Authorization: Bearer ${OCP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-agent-key","expiration":"24h"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")
```

The ServiceAccount must be a member of a MaaS subscription group (e.g., `cluster-admins` for the free tier).

### Step 2: Call the model with the API key

```bash
curl -sk "https://${GATEWAY_HOST}/models-as-a-service/tinyllama-test/v1/chat/completions" \
  --resolve "${GATEWAY_HOST}:443:${CLUSTER_IP}" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama-test","messages":[{"role":"user","content":"Hi"}],"max_tokens":50}'
```

### Python example

```python
import json
import subprocess
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

GATEWAY_HOST = "maas.apps.cluster.example.com"
GATEWAY_SVC = "maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local"

# Resolve ClusterIP for --resolve equivalent
import socket
cluster_ip = socket.getaddrinfo(GATEWAY_SVC, 443)[0][4][0]

# In Python requests, there's no direct --resolve equivalent.
# Option A: use the ClusterIP directly with Host header (works for HTTP, not TLS SNI)
# Option B: mount /etc/hosts or use a custom resolver
# Option C (simplest): just use the external hostname — the latency difference is small for Python apps
response = requests.post(
    f"https://{GATEWAY_HOST}/models-as-a-service/tinyllama-test/v1/chat/completions",
    headers={
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    },
    json={
        "model": "tinyllama-test",
        "messages": [{"role": "user", "content": "Hello"}],
        "max_tokens": 50,
    },
    verify=False,
)
print(response.json())
```

## OpenAI SDK Compatibility

MaaS exposes an OpenAI-compatible API. Use the external hostname as `base_url`:

```python
from openai import OpenAI
import httpx

client = OpenAI(
    base_url=f"https://{GATEWAY_HOST}/models-as-a-service/tinyllama-test/v1",
    api_key=api_key,  # sk-oai-... API key from Step 1
    http_client=httpx.Client(verify=False),  # cluster-internal TLS
)

response = client.chat.completions.create(
    model="tinyllama-test",
    messages=[{"role": "user", "content": "Hello"}],
    max_tokens=50,
)
```

## TLS Certificate Handling

The Gateway uses cluster-internal TLS certificates signed by the OpenShift service CA. For in-cluster workloads there are two approaches:

**Option 1: Skip verification (simplest)**

Set `verify=False` (Python) or `-k` (curl). Acceptable for cluster-internal traffic where the network is trusted.

**Option 2: Trust the service CA**

Mount the OpenShift service CA bundle and point your client to it:

```yaml
volumes:
- name: service-ca
  configMap:
    name: openshift-service-ca.crt
containers:
- name: agent
  volumeMounts:
  - name: service-ca
    mountPath: /etc/pki/tls/service-ca
    readOnly: true
  env:
  - name: REQUESTS_CA_BUNDLE
    value: /etc/pki/tls/service-ca/service-ca.crt
```

## Alternative: Direct Model Access (No Governance)

KServe creates an internal Service for each model. Accessing it directly bypasses all MaaS governance (auth, rate limiting, telemetry):

```
<model>-kserve-workload-svc.<namespace>.svc.cluster.local:8000
```

```bash
curl -sk "https://tinyllama-test-kserve-workload-svc.models-as-a-service.svc.cluster.local:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama-test","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

No authentication required. **Use only for trusted internal workloads** where authentication, rate limiting, and audit are not needed.

## Architecture Diagram

```
                        +---------------------------------------------------+
                        |              OpenShift Cluster                     |
                        |                                                   |
  External              |   +------------------------------------------+    |
  Client ----Route------|-->| Gateway Service (ClusterIP: 172.30.x.x)  |    |
    (API key)           |   | maas-default-gateway-data-science-       |    |
                        |   | gateway-class                            |    |
  In-Cluster            |   +--------------------+---------------------+    |
  Agent Pod ------------|-->|  (--resolve SNI)   |                     |    |
    (API key)           |   |           +--------v---------+           |    |
                        |   |           | Envoy + Authorino|           |    |
                        |   |           | (MaaSAuthPolicy) |           |    |
                        |   |           +--------+---------+           |    |
                        |   |                    |                     |    |
                        |   |         +----------+----------+          |    |
                        |   |         |                     |          |    |
                        |   |    +----v-----+       +-------v------+   |    |
                        |   |    | MaaS API |       | Model Pod    |   |    |
                        |   |    | /maas-api|       | /<ns>/<model>|   |    |
                        |   |    +----------+       +--------------+   |    |
                        |   +------------------------------------------+    |
                        +---------------------------------------------------+
```

The external client traverses: Route -> Load Balancer -> Gateway -> MaaSAuthPolicy -> Model.
The in-cluster agent traverses: Gateway (ClusterIP via `--resolve`) -> MaaSAuthPolicy -> Model, skipping the Route and load balancer entirely.
