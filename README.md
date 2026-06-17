# Redis Connectivity Test (AKS / Azure Cache for Redis)

A layered connectivity and health test for validating pod-to-Redis
connectivity from inside AKS, against Azure Cache for Redis (or Azure
Managed Redis). Each network/protocol layer is tested independently so a
failure tells you *where* the problem is, not just *that* something failed.

## Why a CronJob (not a DaemonSet) by default

Pod connectivity failures to a managed PaaS service like Azure Cache for
Redis are almost always subnet/NSG/route-table/DNS/TLS issues that are
consistent across the cluster's normal scheduling -- not node-kernel-level
issues. A periodic Job run from wherever the scheduler places it will catch
the overwhelming majority of real failures, gives you a clean pass/fail
history via `kubectl get jobs`, and avoids N nodes all hammering the cache
with writes every interval.

Use the **DaemonSet variant** (`03-daemonset.yaml`) when you specifically
need to rule in/out node-specific issues -- e.g. a bad NSG association on one
node, asymmetric routing via a UDR/NVA that only affects part of the node
pool, or a CNI/DNS issue isolated to certain nodes.

Both share the same script and image; only the env vars (`MODE`,
`CHECK_INTERVAL`) and the manifest shape differ.

## What it checks, in order

1. **Env vars** -- confirms `REDIS_HOSTNAME` / `REDIS_PORT` / `REDIS_ACCESS_KEY` are present before doing anything else.
2. **DNS resolution** -- tries `getent`, `nslookup`, `dig`, then a Python `socket.getaddrinfo` fallback, since minimal/distroless images often lack one or more of these tools.
3. **TCP reachability** -- `nc` wrapped in an explicit `timeout`, with a `/dev/tcp` fallback if `nc` isn't present. (Testing found `nc -w` timeout enforcement is inconsistent across implementations -- the explicit outer `timeout` is what actually bounds worst-case runtime.)
4. **TLS handshake + certificate validation** -- verifies the chain validates (`Verify return code: 0`) and parses the certificate's expiry date, warning if it's within `CERT_EXPIRY_WARN_DAYS`.
5. **AUTH + PING** -- distinguishes auth failures, timeouts, and other failures from each other in the error message, since these have different root causes (rotated key vs. NSG drop vs. something else).
6. **Cluster mode auto-detection** -- runs `CLUSTER INFO` and applies `-c` to subsequent commands if clustering is enabled, avoiding false-positive `MOVED` errors on Premium-clustered or Enterprise/OSS-cluster-policy caches.
7. **Read/write test** -- `SET`/`GET` plus `HSET`/`HGET`/`INCR` as a secondary check (catches issues that pure string commands sometimes miss), then cleans up with `DEL`.
8. **Latency sampling** -- a bounded number of `PING` round-trips (not the unbounded `redis-cli --latency` loop), with configurable warn/fail thresholds.
9. **Server-side health** -- `INFO clients/stats/memory/replication/errorstats`, surfacing rejected connections, evictions, replica link status, and error counts as warnings.
10. **Orphaned key cleanup** -- best-effort `SCAN`-based (not `KEYS`, which blocks) cleanup of test keys from any prior failed run.

Every layer's failure short-circuits the layers below it (marked `SKIP`,
not silently omitted), so a DNS failure doesn't waste time attempting TCP,
TLS, and auth against a host that never resolved.

## Output

Set `OUTPUT_FORMAT` to `text` (human-readable, colorized, for `kubectl
logs`), `json` (single-line JSON summary, for log-pipeline parsing/alerting),
or `both` (default in the provided ConfigMap).

Exit code is `0` if every check is `PASS` or `WARN`, `1` if any check is
`FAIL`. `WARN` does not fail the run by default (e.g. a cert expiring in 25
days, or elevated latency) -- tune `LATENCY_FAIL_MS` if you want latency
breaches to fail the run outright.

## Files

| File | Purpose |
|---|---|
| `redis-connectivity-test.sh` | The test script itself |
| `Dockerfile` | Builds the test image (Debian-slim, not Alpine -- see note in Dockerfile) |
| `01-configmap-secret.yaml` | Non-sensitive config + access key (replace with your real secret source) |
| `02-cronjob.yaml` | **Recommended default** -- periodic single-run test |
| `03-daemonset.yaml` | Per-node continuous variant for node-specific troubleshooting |

## Quick start

```bash
# 1. Build and push the image
docker build -t <your-registry>/redis-connectivity-test:latest .
docker push <your-registry>/redis-connectivity-test:latest

# 2. Edit 01-configmap-secret.yaml with your actual REDIS_HOSTNAME and key
#    (ideally REDIS_ACCESS_KEY should come from your existing secret source --
#    Key Vault via CSI driver, External Secrets Operator, etc. -- not a literal)

# 3. Edit the image reference in 02-cronjob.yaml (and 03-daemonset.yaml if using it)

kubectl apply -f 01-configmap-secret.yaml
kubectl apply -f 02-cronjob.yaml

# Trigger an immediate run without waiting for the schedule:
kubectl create job --from=cronjob/redis-connectivity-test redis-conn-test-manual-1

kubectl logs -l app=redis-connectivity-test --tail=100
```

## Interpreting common failures

- **`dns_resolution` FAILs**: check CoreDNS pod health, the cluster's DNS
  config (e.g. custom DNS servers set on the VNet that don't forward Azure
  Private DNS Zone queries correctly), and if you're using Private Link,
  confirm the Private DNS Zone is actually linked to the AKS VNet.
- **`tcp_reachability` FAILs but DNS passes**: almost always an NSG rule, a
  UDR routing egress through a firewall/NVA that's blocking the port, or
  (less commonly) the cache itself being firewalled to specific source
  IPs/VNets that don't include your AKS subnet.
- **`tls_handshake` FAILs**: usually a missing/outdated CA bundle in the
  container image (rare with `ca-certificates` installed, as in the provided
  Dockerfile), or an SNI mismatch if you're going through a proxy.
- **`auth_ping` FAILs with an auth-related message**: the access key has
  likely been rotated. Azure Cache for Redis supports primary/secondary keys
  specifically so you can rotate one while the other stays valid -- check
  which key your Secret currently holds against the portal.
- **`auth_ping` FAILs with a timeout** despite TCP/TLS passing: this points
  at asymmetric routing or a stateful firewall dropping the data-plane
  traffic after allowing the initial handshake -- a classic NVA/UDR
  misconfiguration pattern.
- **`server_health` shows `evicted_keys` increasing over repeated runs**:
  memory pressure on the cache -- check `maxmemory-policy` and consider
  scaling the tier, this isn't a connectivity issue but is worth catching
  before it becomes one.

## A note on retirement

Microsoft has announced a retirement timeline for Azure Cache for Redis
across all SKUs, recommending migration to Azure Managed Redis. This script
works unchanged against either, since both expose the same `redis-cli`
protocol surface -- but worth factoring into any longer-term planning around
this tooling.

## Limitations / things not covered

- This tests from the AKS pod's perspective only. It does not validate
  Redis-side configuration like firewall rules restricting allowed source
  IPs/VNets -- a FAIL here could mean either side is misconfigured.
- Geo-replication / multi-region failover behavior isn't tested.
- If you've moved to Microsoft Entra ID token-based auth instead of access
  keys, the AUTH step needs a token-acquisition step substituted in -- this
  script assumes access-key auth as specified in the original request.
