#!/usr/bin/env bash
#
# redis-connectivity-test.sh
#
# Layered connectivity/health test for Azure Cache for Redis (or Azure Managed
# Redis) from inside an AKS pod. Each layer is tested independently so a
# failure tells you WHERE in the stack the problem is (DNS vs NSG/firewall vs
# TLS/cert vs auth vs cluster routing vs data plane vs server-side health),
# rather than a single opaque "redis-cli failed" message.
#
# Designed to run as:
#   - a Kubernetes Job/CronJob (MODE=once)         <- default, recommended
#   - a Kubernetes DaemonSet/sidecar (MODE=loop)    <- per-node validation
#
# Exit code: 0 if all checks pass, 1 if any REQUIRED check fails.
# Optional checks (latency, INFO stats) record findings but don't fail the run
# unless THRESHOLD breaches are configured and exceeded.
#
# -----------------------------------------------------------------------
# Required env vars:
#   REDIS_HOSTNAME      e.g. mycache.redis.cache.windows.net
#   REDIS_PORT           6380 (TLS, Basic/Std/Premium) | 6379 (non-TLS) | 10000 (Enterprise)
#   REDIS_ACCESS_KEY     primary/secondary access key (omit/blank if using AAD/Entra auth - see note)
#
# Optional env vars:
#   REDIS_TLS             "true" (default) | "false"
#   REDIS_CLUSTER_MODE    "auto" (default) | "true" | "false"  -- auto runs CLUSTER INFO to detect
#   MODE                  "once" (default) | "loop"
#   CHECK_INTERVAL        seconds between loops when MODE=loop (default 60)
#   OUTPUT_FORMAT         "text" (default) | "json" | "both"
#   TCP_TIMEOUT           seconds for nc/openssl connection attempts (default 5)
#   LATENCY_SAMPLES       number of PING round-trips to sample (default 10)
#   LATENCY_WARN_MS       warn threshold for avg latency in ms (default 50)
#   LATENCY_FAIL_MS       fail threshold for avg latency in ms (default 0 = disabled)
#   CERT_EXPIRY_WARN_DAYS warn if server cert expires within N days (default 30)
#   SKIP_WRITE_TEST        "false" (default) | "true" -- set true for read-only/locked-down environments
#   TEST_KEY_PREFIX        prefix for ephemeral test keys (default "conn-test")
#
# Note on auth: Azure Cache for Redis also supports Microsoft Entra ID
# authentication as an alternative to access keys. This script tests
# access-key auth, since that's what's in scope. If you've moved to Entra ID
# token auth, the AUTH/PING step needs a token-fetch step substituted in --
# ask if you want that variant.
# -----------------------------------------------------------------------

set -u
set -o pipefail

# ---------- Defaults ----------
REDIS_TLS="${REDIS_TLS:-true}"
REDIS_CLUSTER_MODE="${REDIS_CLUSTER_MODE:-auto}"
MODE="${MODE:-once}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"
TCP_TIMEOUT="${TCP_TIMEOUT:-5}"
LATENCY_SAMPLES="${LATENCY_SAMPLES:-10}"
LATENCY_WARN_MS="${LATENCY_WARN_MS:-50}"
LATENCY_FAIL_MS="${LATENCY_FAIL_MS:-0}"
CERT_EXPIRY_WARN_DAYS="${CERT_EXPIRY_WARN_DAYS:-30}"
SKIP_WRITE_TEST="${SKIP_WRITE_TEST:-false}"
TEST_KEY_PREFIX="${TEST_KEY_PREFIX:-conn-test}"

SCRIPT_START_MS=$(date +%s%3N 2>/dev/null || date +%s000)
HOSTNAME_LOCAL="$(hostname 2>/dev/null || echo unknown)"
NODE_NAME="${NODE_NAME:-${KUBE_NODE_NAME:-unknown}}"   # populated via downward API in the DaemonSet manifest

# ---------- Result tracking ----------
declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()     # PASS | FAIL | WARN | SKIP
declare -a RESULT_DETAIL=()
declare -a RESULT_DURATION_MS=()
OVERALL_EXIT=0

record() {
  local name="$1" status="$2" detail="$3" duration_ms="${4:-0}"
  RESULT_NAMES+=("$name")
  RESULT_STATUS+=("$status")
  RESULT_DETAIL+=("$detail")
  RESULT_DURATION_MS+=("$duration_ms")
  if [[ "$status" == "FAIL" ]]; then
    OVERALL_EXIT=1
  fi
  if [[ "$OUTPUT_FORMAT" == "text" || "$OUTPUT_FORMAT" == "both" ]]; then
    local color_reset="\033[0m" color=""
    case "$status" in
      PASS) color="\033[32m" ;;
      FAIL) color="\033[31m" ;;
      WARN) color="\033[33m" ;;
      SKIP) color="\033[90m" ;;
    esac
    printf "[%s] %b%-4s%b %-28s %s (%sms)\n" \
      "$(date -u +%H:%M:%S)" "$color" "$status" "$color_reset" "$name" "$detail" "$duration_ms"
  fi
}

timed() {
  # usage: timed <varname_to_store_ms> <command...>
  local __outvar="$1"; shift
  local t0 t1
  t0=$(date +%s%3N 2>/dev/null || date +%s000)
  "$@"
  local rc=$?
  t1=$(date +%s%3N 2>/dev/null || date +%s000)
  printf -v "$__outvar" '%d' "$(( t1 - t0 ))"
  return $rc
}

# ---------- Pre-flight: required env vars ----------
check_env_vars() {
  local missing=()
  local t0 ms
  t0=$(date +%s%3N 2>/dev/null || date +%s000)

  [[ -z "${REDIS_HOSTNAME:-}" ]] && missing+=("REDIS_HOSTNAME")
  [[ -z "${REDIS_PORT:-}" ]] && missing+=("REDIS_PORT")
  [[ -z "${REDIS_ACCESS_KEY:-}" ]] && missing+=("REDIS_ACCESS_KEY (or set REDIS_ACCESS_KEY='' explicitly if using Entra auth / unauthenticated)")

  ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))

  if [[ ${#missing[@]} -gt 0 ]]; then
    record "env_vars" "FAIL" "Missing: ${missing[*]}" "$ms"
    return 1
  fi

  local present
  present=$(printf 'REDIS_HOSTNAME=%s REDIS_PORT=%s REDIS_TLS=%s REDIS_CLUSTER_MODE=%s' \
    "$REDIS_HOSTNAME" "$REDIS_PORT" "$REDIS_TLS" "$REDIS_CLUSTER_MODE")
  record "env_vars" "PASS" "$present" "$ms"
  return 0
}

# ---------- 1. DNS resolution ----------
check_dns() {
  local t0 ms resolved="" tool_used=""
  t0=$(date +%s%3N 2>/dev/null || date +%s000)

  if command -v getent >/dev/null 2>&1; then
    resolved=$(getent hosts "$REDIS_HOSTNAME" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)
    tool_used="getent"
  fi

  if [[ -z "$resolved" ]] && command -v nslookup >/dev/null 2>&1; then
    resolved=$(nslookup "$REDIS_HOSTNAME" 2>/dev/null | awk '/^Address: /{print $2}' | sort -u | paste -sd, -)
    tool_used="nslookup"
  fi

  if [[ -z "$resolved" ]] && command -v dig >/dev/null 2>&1; then
    resolved=$(dig +short "$REDIS_HOSTNAME" A 2>/dev/null | paste -sd, -)
    tool_used="dig"
  fi

  if [[ -z "$resolved" ]] && command -v python3 >/dev/null 2>&1; then
    resolved=$(python3 - "$REDIS_HOSTNAME" <<'PYEOF' 2>/dev/null
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None)
    print(",".join(sorted({i[4][0] for i in infos})))
except Exception:
    pass
PYEOF
)
    tool_used="python3-socket"
  fi

  ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))

  if [[ -z "$resolved" ]]; then
    record "dns_resolution" "FAIL" "Could not resolve $REDIS_HOSTNAME via any method (tried getent/nslookup/dig/python3). Check CoreDNS, Private DNS Zone linkage, or VNet DNS settings." "$ms"
    return 1
  fi

  record "dns_resolution" "PASS" "$REDIS_HOSTNAME -> $resolved (via $tool_used)" "$ms"
  return 0
}

# ---------- 2. TCP reachability ----------
check_tcp() {
  local t0 ms
  t0=$(date +%s%3N 2>/dev/null || date +%s000)

  if command -v nc >/dev/null 2>&1; then
    if timeout "$((TCP_TIMEOUT + 1))" nc -vz -w "$TCP_TIMEOUT" "$REDIS_HOSTNAME" "$REDIS_PORT" >/tmp/nc_out 2>&1; then
      ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))
      record "tcp_reachability" "PASS" "TCP connect to $REDIS_HOSTNAME:$REDIS_PORT succeeded" "$ms"
      return 0
    else
      ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))
      local detail
      detail=$(tail -n1 /tmp/nc_out 2>/dev/null)
      record "tcp_reachability" "FAIL" "TCP connect failed: ${detail:-timeout/refused}. Check NSG rules, UDR/firewall egress, and Private Endpoint/Private Link DNS if applicable." "$ms"
      return 1
    fi
  elif command -v timeout >/dev/null 2>&1; then
    # Fallback using /dev/tcp if nc is unavailable
    if timeout "$TCP_TIMEOUT" bash -c "exec 3<>/dev/tcp/${REDIS_HOSTNAME}/${REDIS_PORT}" 2>/tmp/tcp_out; then
      ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))
      record "tcp_reachability" "PASS" "TCP connect to $REDIS_HOSTNAME:$REDIS_PORT succeeded (via /dev/tcp fallback)" "$ms"
      return 0
    else
      ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))
      record "tcp_reachability" "FAIL" "TCP connect failed (via /dev/tcp fallback). Check NSG rules and egress firewall rules." "$ms"
      return 1
    fi
  else
    ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))
    record "tcp_reachability" "SKIP" "Neither nc nor bash /dev/tcp available in this image" "$ms"
    return 2
  fi
}

# ---------- 3. TLS handshake / certificate validation ----------
check_tls() {
  if [[ "$REDIS_TLS" != "true" ]]; then
    record "tls_handshake" "SKIP" "REDIS_TLS=false, skipping TLS check" "0"
    return 0
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    record "tls_handshake" "SKIP" "openssl not available in this image" "0"
    return 2
  fi

  local t0 ms cert_text not_after expiry_epoch now_epoch days_left
  t0=$(date +%s%3N 2>/dev/null || date +%s000)

  cert_text=$(echo -n "" | timeout "$TCP_TIMEOUT" openssl s_client \
    -connect "${REDIS_HOSTNAME}:${REDIS_PORT}" \
    -servername "$REDIS_HOSTNAME" \
    2>/tmp/openssl_err </dev/null)

  ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))

  if [[ -z "$cert_text" ]]; then
    record "tls_handshake" "FAIL" "TLS handshake produced no output: $(tail -n1 /tmp/openssl_err 2>/dev/null)" "$ms"
    return 1
  fi

  if ! echo "$cert_text" | grep -q "Verify return code: 0"; then
    local verify_line
    verify_line=$(echo "$cert_text" | grep "Verify return code" | tail -n1)
    record "tls_handshake" "FAIL" "Certificate verification failed: ${verify_line:-unknown}. Check CA bundle in image / SNI mismatch." "$ms"
    return 1
  fi

  not_after=$(echo "$cert_text" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
  if [[ -n "$not_after" ]]; then
    expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null)
    now_epoch=$(date +%s)
    if [[ -n "$expiry_epoch" ]]; then
      days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      if (( days_left < 0 )); then
        record "tls_handshake" "FAIL" "Server certificate EXPIRED ($not_after)" "$ms"
        return 1
      elif (( days_left < CERT_EXPIRY_WARN_DAYS )); then
        record "tls_handshake" "WARN" "TLS OK, but cert expires in ${days_left}d ($not_after)" "$ms"
        return 0
      else
        record "tls_handshake" "PASS" "TLS verified OK, cert valid until $not_after (${days_left}d remaining)" "$ms"
        return 0
      fi
    fi
  fi

  record "tls_handshake" "PASS" "TLS handshake and cert verification succeeded" "$ms"
  return 0
}

# ---------- redis-cli wrapper ----------
RCLI_BASE=()
build_rcli_base() {
  RCLI_BASE=(redis-cli -h "$REDIS_HOSTNAME" -p "$REDIS_PORT" --no-auth-warning)
  if [[ -n "${REDIS_ACCESS_KEY:-}" ]]; then
    RCLI_BASE+=(-a "$REDIS_ACCESS_KEY")
  fi
  if [[ "$REDIS_TLS" == "true" ]]; then
    RCLI_BASE+=(--tls)
  fi
  if [[ "$REDIS_CLUSTER_MODE" == "true" ]]; then
    RCLI_BASE+=(-c)
  fi
}

rcli() {
  timeout "${TCP_TIMEOUT}" "${RCLI_BASE[@]}" "$@"
}

# ---------- 4. AUTH + PING ----------
check_auth_ping() {
  if ! command -v redis-cli >/dev/null 2>&1; then
    record "auth_ping" "FAIL" "redis-cli binary not found in this image" "0"
    return 1
  fi

  local t0 ms out rc
  t0=$(date +%s%3N 2>/dev/null || date +%s000)
  out=$(rcli PING 2>&1)
  rc=$?
  ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))

  if [[ $rc -ne 0 ]]; then
    if echo "$out" | grep -qi "NOAUTH\|WRONGPASS\|invalid password\|AUTH"; then
      record "auth_ping" "FAIL" "Authentication failed: $out. Check REDIS_ACCESS_KEY (may be rotated/expired) or Entra auth config." "$ms"
    elif echo "$out" | grep -qi "timed out\|timeout"; then
      record "auth_ping" "FAIL" "PING timed out: $out. TCP/TLS layers may have passed but data-plane traffic is being dropped (check NSG, possible asymmetric routing)." "$ms"
    else
      record "auth_ping" "FAIL" "PING failed: $out" "$ms"
    fi
    return 1
  fi

  if [[ "$out" != "PONG" ]]; then
    record "auth_ping" "FAIL" "Unexpected PING response: $out" "$ms"
    return 1
  fi

  record "auth_ping" "PASS" "PING -> PONG, auth succeeded" "$ms"
  return 0
}

# ---------- Detect clustering (if auto) ----------
detect_cluster_mode() {
  if [[ "$REDIS_CLUSTER_MODE" != "auto" ]]; then
    return 0
  fi
  local out
  out=$(timeout "$TCP_TIMEOUT" "${RCLI_BASE[@]}" CLUSTER INFO 2>/dev/null)
  if echo "$out" | grep -q "cluster_enabled:1"; then
    REDIS_CLUSTER_MODE="true"
    RCLI_BASE+=(-c)
    record "cluster_detect" "PASS" "Clustering auto-detected as ENABLED; -c flag now applied to subsequent commands" "0"
  else
    REDIS_CLUSTER_MODE="false"
    record "cluster_detect" "PASS" "Clustering auto-detected as disabled (or CLUSTER INFO unsupported on this tier)" "0"
  fi
}

# ---------- 5. Read/write test (multiple data types) ----------
check_read_write() {
  if [[ "$SKIP_WRITE_TEST" == "true" ]]; then
    record "read_write" "SKIP" "SKIP_WRITE_TEST=true" "0"
    return 0
  fi

  local key="${TEST_KEY_PREFIX}:${HOSTNAME_LOCAL}:$(date +%s)"
  local hkey="${key}:hash"
  local t0 ms set_out get_out del_out hset_out hget_out incr_out

  t0=$(date +%s%3N 2>/dev/null || date +%s000)

  set_out=$(rcli SET "$key" "ok" EX 60 2>&1)
  if [[ "$set_out" != "OK" ]]; then
    ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))
    record "read_write" "FAIL" "SET failed: $set_out" "$ms"
    return 1
  fi

  get_out=$(rcli GET "$key" 2>&1)
  if [[ "$get_out" != "ok" ]]; then
    ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))
    record "read_write" "FAIL" "GET returned unexpected value: '$get_out' (expected 'ok')" "$ms"
    rcli DEL "$key" >/dev/null 2>&1
    return 1
  fi

  # Secondary data-type check: HSET/HGET/INCR catch issues that plain
  # string SET/GET sometimes miss (e.g. command-specific cluster redirects,
  # or a proxy/firewall doing naive protocol inspection on string commands only).
  hset_out=$(rcli HSET "$hkey" field1 "val1" 2>&1)
  hget_out=$(rcli HGET "$hkey" field1 2>&1)
  incr_out=$(rcli INCR "${key}:counter" 2>&1)

  del_out=$(rcli DEL "$key" "$hkey" "${key}:counter" 2>&1)

  ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))

  local issues=()
  [[ "$hget_out" != "val1" ]] && issues+=("HSET/HGET mismatch: got '$hget_out'")
  [[ "$incr_out" != "1" ]] && issues+=("INCR unexpected result: got '$incr_out'")
  if [[ "$del_out" =~ ^[0-9]+$ ]]; then
    (( del_out < 2 )) && issues+=("DEL cleanup removed fewer keys than expected (deleted $del_out of 3, string key cleanup verified separately)")
  else
    issues+=("DEL returned non-numeric/unexpected response: '$del_out' -- cleanup may have failed, check manually for orphaned key '$key'")
  fi

  if [[ ${#issues[@]} -gt 0 ]]; then
    record "read_write" "WARN" "String SET/GET OK, but secondary checks had issues: ${issues[*]}" "$ms"
    return 0
  fi

  record "read_write" "PASS" "SET/GET/HSET/HGET/INCR/DEL all succeeded (key=$key)" "$ms"
  return 0
}

# ---------- 6. Latency sampling ----------
check_latency() {
  if ! command -v redis-cli >/dev/null 2>&1; then
    record "latency" "SKIP" "redis-cli not available" "0"
    return 2
  fi

  local t0 ms total=0 i sample_ms samples=() failures=0
  t0=$(date +%s%3N 2>/dev/null || date +%s000)

  for (( i=0; i<LATENCY_SAMPLES; i++ )); do
    local s0 s1
    s0=$(date +%s%3N 2>/dev/null || date +%s000)
    if ! rcli PING >/dev/null 2>&1; then
      failures=$((failures+1))
      continue
    fi
    s1=$(date +%s%3N 2>/dev/null || date +%s000)
    sample_ms=$(( s1 - s0 ))
    samples+=("$sample_ms")
    total=$(( total + sample_ms ))
  done

  ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))

  local successful=${#samples[@]}
  if (( successful == 0 )); then
    record "latency" "FAIL" "All $LATENCY_SAMPLES latency PING samples failed" "$ms"
    return 1
  fi

  local avg=$(( total / successful ))
  local max=0 min=999999
  for s in "${samples[@]}"; do
    (( s > max )) && max=$s
    (( s < min )) && min=$s
  done

  local detail="avg=${avg}ms min=${min}ms max=${max}ms over ${successful}/${LATENCY_SAMPLES} samples"
  [[ $failures -gt 0 ]] && detail="$detail ($failures failed)"

  if (( LATENCY_FAIL_MS > 0 && avg > LATENCY_FAIL_MS )); then
    record "latency" "FAIL" "$detail -- exceeds LATENCY_FAIL_MS=$LATENCY_FAIL_MS" "$ms"
    return 1
  elif (( avg > LATENCY_WARN_MS )); then
    record "latency" "WARN" "$detail -- exceeds LATENCY_WARN_MS=$LATENCY_WARN_MS" "$ms"
    return 0
  else
    record "latency" "PASS" "$detail" "$ms"
    return 0
  fi
}

# ---------- 7. Server-side health indicators ----------
check_server_health() {
  local t0 ms
  t0=$(date +%s%3N 2>/dev/null || date +%s000)

  local info_clients info_stats info_errorstats info_memory info_replication
  info_clients=$(rcli INFO clients 2>&1)
  info_stats=$(rcli INFO stats 2>&1)
  info_errorstats=$(rcli INFO errorstats 2>&1)
  info_memory=$(rcli INFO memory 2>&1)
  info_replication=$(rcli INFO replication 2>&1)

  ms=$(( $(date +%s%3N 2>/dev/null || date +%s000) - t0 ))

  if [[ -z "$info_clients" ]]; then
    record "server_health" "FAIL" "INFO commands returned no data; server may be unreachable for data-plane commands despite PING succeeding" "$ms"
    return 1
  fi

  local connected_clients blocked_clients
  connected_clients=$(echo "$info_clients" | grep -oP 'connected_clients:\K[0-9]+' || echo "?")
  blocked_clients=$(echo "$info_clients" | grep -oP 'blocked_clients:\K[0-9]+' || echo "0")

  local rejected_conns evicted_keys expired_keys
  rejected_conns=$(echo "$info_stats" | grep -oP 'rejected_connections:\K[0-9]+' || echo "0")
  evicted_keys=$(echo "$info_stats" | grep -oP 'evicted_keys:\K[0-9]+' || echo "0")
  expired_keys=$(echo "$info_stats" | grep -oP 'expired_keys:\K[0-9]+' || echo "0")

  local used_memory_human maxmemory_human maxmemory_policy
  used_memory_human=$(echo "$info_memory" | grep -oP 'used_memory_human:\K.+' | tr -d '\r' || echo "?")
  maxmemory_human=$(echo "$info_memory" | grep -oP 'maxmemory_human:\K.+' | tr -d '\r' || echo "?")
  maxmemory_policy=$(echo "$info_memory" | grep -oP 'maxmemory_policy:\K.+' | tr -d '\r' || echo "?")

  local role connected_slaves master_link_status
  role=$(echo "$info_replication" | grep -oP '^role:\K.+' | tr -d '\r' || echo "?")
  connected_slaves=$(echo "$info_replication" | grep -oP 'connected_slaves:\K[0-9]+' || echo "?")
  master_link_status=$(echo "$info_replication" | grep -oP 'master_link_status:\K.+' | tr -d '\r' || echo "")

  local error_count
  error_count=$(echo "$info_errorstats" | grep -c '^errorstat_' || echo "0")

  local detail="clients=${connected_clients} blocked=${blocked_clients} rejected_conns=${rejected_conns} evicted=${evicted_keys} mem=${used_memory_human}/${maxmemory_human} policy=${maxmemory_policy} role=${role}"
  [[ -n "$master_link_status" ]] && detail="$detail replica_link=${master_link_status}"

  local warnings=()
  (( rejected_conns > 0 )) && warnings+=("rejected_connections=$rejected_conns (possible maxclients limit hit)")
  (( evicted_keys > 0 )) && warnings+=("evicted_keys=$evicted_keys (memory pressure -- check maxmemory-policy and consider scaling tier)")
  [[ "$master_link_status" == "down" ]] && warnings+=("replica link to master is DOWN")
  (( error_count > 0 )) && warnings+=("server reports $error_count distinct error type(s) in errorstats")

  if [[ ${#warnings[@]} -gt 0 ]]; then
    record "server_health" "WARN" "$detail | Issues: ${warnings[*]}" "$ms"
  else
    record "server_health" "PASS" "$detail" "$ms"
  fi

  if [[ $error_count -gt 0 ]]; then
    echo "$info_errorstats" | grep '^errorstat_' | while read -r line; do
      [[ "$OUTPUT_FORMAT" == "text" || "$OUTPUT_FORMAT" == "both" ]] && echo "    errorstat: $line"
    done
  fi

  return 0
}

# ---------- Cleanup any leftover test keys from prior failed runs (best effort) ----------
cleanup_orphaned_keys() {
  command -v redis-cli >/dev/null 2>&1 || return 0
  local pattern="${TEST_KEY_PREFIX}:${HOSTNAME_LOCAL}:*"
  # SCAN is cluster-safe and non-blocking, unlike KEYS; best-effort, ignore failures
  local cursor=0
  while true; do
    local scan_out cursor_next keys
    scan_out=$(rcli SCAN "$cursor" MATCH "$pattern" COUNT 100 2>/dev/null) || break
    cursor_next=$(echo "$scan_out" | head -n1)
    keys=$(echo "$scan_out" | tail -n +2)
    [[ -n "$keys" ]] && echo "$keys" | xargs -r -n1 -I{} rcli DEL "{}" >/dev/null 2>&1
    [[ "$cursor_next" == "0" || -z "$cursor_next" ]] && break
    cursor="$cursor_next"
  done
}

# ---------- JSON summary emitter ----------
emit_json_summary() {
  local json="{"
  json+="\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  json+="\"node\":\"${NODE_NAME}\","
  json+="\"pod\":\"${HOSTNAME_LOCAL}\","
  json+="\"target\":\"${REDIS_HOSTNAME}:${REDIS_PORT}\","
  json+="\"overall_status\":\"$([[ $OVERALL_EXIT -eq 0 ]] && echo PASS || echo FAIL)\","
  json+="\"duration_ms\":$(( $(date +%s%3N 2>/dev/null || date +%s000) - SCRIPT_START_MS )),"
  json+="\"checks\":["
  local i n=${#RESULT_NAMES[@]}
  for (( i=0; i<n; i++ )); do
    local detail_escaped
    detail_escaped=$(echo "${RESULT_DETAIL[$i]}" | sed 's/\\/\\\\/g; s/"/\\"/g')
    json+="{\"name\":\"${RESULT_NAMES[$i]}\",\"status\":\"${RESULT_STATUS[$i]}\",\"detail\":\"${detail_escaped}\",\"duration_ms\":${RESULT_DURATION_MS[$i]}}"
    (( i < n-1 )) && json+=","
  done
  json+="]}"

  if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "both" ]]; then
    echo "$json"
  fi
}

# ---------- Main run ----------
run_all_checks() {
  RESULT_NAMES=(); RESULT_STATUS=(); RESULT_DETAIL=(); RESULT_DURATION_MS=()
  OVERALL_EXIT=0
  SCRIPT_START_MS=$(date +%s%3N 2>/dev/null || date +%s000)

  [[ "$OUTPUT_FORMAT" == "text" || "$OUTPUT_FORMAT" == "both" ]] && \
    echo "===== Redis connectivity test :: $(date -u +%Y-%m-%dT%H:%M:%SZ) :: node=${NODE_NAME} pod=${HOSTNAME_LOCAL} ====="

  if ! check_env_vars; then
    REDIS_HOSTNAME="${REDIS_HOSTNAME:-unset}"
    REDIS_PORT="${REDIS_PORT:-unset}"
    emit_json_summary
    return 1
  fi

  check_dns
  local dns_rc=$?

  if [[ $dns_rc -eq 0 ]]; then
    check_tcp
  else
    record "tcp_reachability" "SKIP" "Skipped: DNS resolution failed" "0"
  fi

  local tcp_rc=$?
  if [[ $dns_rc -eq 0 && $tcp_rc -eq 0 ]]; then
    check_tls
  else
    record "tls_handshake" "SKIP" "Skipped: prior layer failed" "0"
  fi

  build_rcli_base

  if [[ $dns_rc -eq 0 && $tcp_rc -eq 0 ]]; then
    check_auth_ping
    local auth_rc=$?
  else
    record "auth_ping" "SKIP" "Skipped: prior layer failed" "0"
    auth_rc=1
  fi

  if [[ $auth_rc -eq 0 ]]; then
    detect_cluster_mode
    check_read_write
    check_latency
    check_server_health
    cleanup_orphaned_keys
  else
    record "cluster_detect" "SKIP" "Skipped: auth/ping failed" "0"
    record "read_write" "SKIP" "Skipped: auth/ping failed" "0"
    record "latency" "SKIP" "Skipped: auth/ping failed" "0"
    record "server_health" "SKIP" "Skipped: auth/ping failed" "0"
  fi

  if [[ "$OUTPUT_FORMAT" == "text" || "$OUTPUT_FORMAT" == "both" ]]; then
    echo "===== Result: $([[ $OVERALL_EXIT -eq 0 ]] && echo "ALL CHECKS PASSED" || echo "FAILURES DETECTED") ====="
  fi

  emit_json_summary

  return $OVERALL_EXIT
}

# ---------- Entrypoint ----------
if [[ "$MODE" == "loop" ]]; then
  trap 'echo "Received termination signal, exiting loop."; exit 0' SIGTERM SIGINT
  while true; do
    run_all_checks || true
    sleep "$CHECK_INTERVAL" &
    wait $!
  done
else
  run_all_checks
  exit $?
fi
