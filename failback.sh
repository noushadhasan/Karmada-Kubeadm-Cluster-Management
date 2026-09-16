#!/bin/bash
# Karmada automated failback to the primary affinity group.
#
# Karmada's scheduler walks clusterAffinities FORWARD only:
#   affinityIndex := getAffinityIndex(placement.ClusterAffinities, status.SchedulerObservedAffinityName)
#   for affinityIndex < len(...) { ... }
# and getAffinityIndex returns 0 only when the observed name is "".
# Nothing in Karmada ever clears that field, so failback requires clearing it
# externally, then triggering a reschedule. WorkloadRebalancer does NOT do this
# (it only sets rescheduleTriggeredAt) so it cannot fail back.

set -uo pipefail

export KUBECONFIG=/etc/karmada/config/karmada.config

PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-cluster-1}"
PRIMARY_AFFINITY="${PRIMARY_AFFINITY:-primary-k2}"
SETTLE_MINUTES="${SETTLE_MINUTES:-15}"
BATCH_SIZE="${BATCH_SIZE:-20}"
BATCH_PAUSE="${BATCH_PAUSE:-15}"
MAX_PER_RUN="${MAX_PER_RUN:-50}"
DRY_RUN="${DRY_RUN:-0}"
ENABLED="${ENABLED:-false}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# ---- Gate 0: kill switch --------------------------------------------------
if [ "$ENABLED" != "true" ]; then
  log "DISABLED (enabled=$ENABLED). Exiting without action."
  exit 0
fi

# ---- Gate 1: control plane reachable --------------------------------------
if ! kubectl get clusters -o name >/dev/null 2>&1; then
  log "ERROR: cannot list clusters from the Karmada control plane. Aborting."
  exit 1
fi

# ---- Gate 2: primary health ------------------------------------------------
READY=$(kubectl get cluster "$PRIMARY_CLUSTER" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)
TAINTS=$(kubectl get cluster "$PRIMARY_CLUSTER" -o jsonpath='{.spec.taints}' 2>/dev/null)
TSTAMP=$(kubectl get cluster "$PRIMARY_CLUSTER" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{end}' 2>/dev/null)

if [ "$READY" != "True" ]; then
  log "SKIP: primary $PRIMARY_CLUSTER Ready=$READY"
  exit 0
fi

if [ -n "$TAINTS" ]; then
  log "SKIP: primary $PRIMARY_CLUSTER still carries taints: $TAINTS"
  log "      ClusterTaintPolicy has not cleared them; failback would be evicted."
  exit 0
fi

NOW=$(date -u +%s)
THEN=$(printf '"%s"' "$TSTAMP" | jq 'fromdateiso8601' 2>/dev/null)
if [ -z "$THEN" ] || [ "$THEN" = "null" ]; then
  log "ERROR: cannot parse Ready lastTransitionTime='$TSTAMP'. Aborting."
  exit 1
fi

AGE_MIN=$(( (NOW - THEN) / 60 ))
if [ "$AGE_MIN" -lt "$SETTLE_MINUTES" ]; then
  log "SKIP: primary Ready for only ${AGE_MIN}m, settle window is ${SETTLE_MINUTES}m."
  exit 0
fi

log "primary $PRIMARY_CLUSTER: Ready, untainted, stable for ${AGE_MIN}m -> proceeding"

# ---- Phase 3: select bindings pinned to a non-primary affinity group -------
JQF='.items[]
     | select(.status.schedulerObservingAffinityName != null)
     | select(.status.schedulerObservingAffinityName != "")
     | select(.status.schedulerObservingAffinityName != $pa)'

SEL_RB=$(kubectl get rb -A -o json 2>/dev/null \
  | jq -r --arg pa "$PRIMARY_AFFINITY" "$JQF"' | "rb \(.metadata.namespace) \(.metadata.name) \(.status.schedulerObservingAffinityName)"')

SEL_CRB=$(kubectl get crb -o json 2>/dev/null \
  | jq -r --arg pa "$PRIMARY_AFFINITY" "$JQF"' | "crb - \(.metadata.name) \(.status.schedulerObservingAffinityName)"')

TARGETS=$(printf '%s\n%s\n' "$SEL_RB" "$SEL_CRB" | sed '/^$/d')
COUNT=$(printf '%s' "$TARGETS" | grep -c . || true)

if [ "${COUNT:-0}" -eq 0 ]; then
  log "nothing to do: no bindings pinned outside '$PRIMARY_AFFINITY'"
  exit 0
fi

log "found $COUNT binding(s) pinned outside '$PRIMARY_AFFINITY'"

if [ "$COUNT" -gt "$MAX_PER_RUN" ]; then
  log "capping this run at MAX_PER_RUN=$MAX_PER_RUN (remainder next run)"
  TARGETS=$(printf '%s\n' "$TARGETS" | head -n "$MAX_PER_RUN")
  COUNT="$MAX_PER_RUN"
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 - would fail back the following, and patch nothing:"
  printf '%s\n' "$TARGETS" | sed 's/^/    /'
  exit 0
fi

# ---- Phase 4: act, in batches ---------------------------------------------
DONE=0
FAILED=0
while read -r KIND NS NAME OBSERVED; do
  [ -z "${KIND:-}" ] && continue

  if [ "$KIND" = "rb" ]; then
    NSARG=(-n "$NS"); RES=rb
  else
    NSARG=(); RES=crb
  fi

  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if kubectl "${NSARG[@]}" patch "$RES" "$NAME" --subresource=status --type=merge \
        -p '{"status":{"schedulerObservingAffinityName":""}}' >/dev/null 2>&1 \
     && kubectl "${NSARG[@]}" patch "$RES" "$NAME" --type=merge \
        -p "{\"spec\":{\"rescheduleTriggeredAt\":\"$TS\"}}" >/dev/null 2>&1; then
    log "  ok   $KIND ${NS}/${NAME} (was '$OBSERVED')"
    DONE=$((DONE + 1))
  else
    log "  FAIL $KIND ${NS}/${NAME} (was '$OBSERVED')"
    FAILED=$((FAILED + 1))
  fi

  if [ "$BATCH_SIZE" -gt 0 ] && [ $(( (DONE + FAILED) % BATCH_SIZE )) -eq 0 ]; then
    log "  -- batch boundary, pausing ${BATCH_PAUSE}s --"
    sleep "$BATCH_PAUSE"
  fi
done <<< "$TARGETS"

log "patched: $DONE ok, $FAILED failed"

# ---- Phase 5: verify -------------------------------------------------------
sleep 15

REMAIN_RB=$(kubectl get rb -A -o json 2>/dev/null \
  | jq -r --arg pa "$PRIMARY_AFFINITY" "$JQF"' | "rb \(.metadata.namespace)/\(.metadata.name)"')
REMAIN_CRB=$(kubectl get crb -o json 2>/dev/null \
  | jq -r --arg pa "$PRIMARY_AFFINITY" "$JQF"' | "crb \(.metadata.name)"')
REMAIN=$(printf '%s\n%s\n' "$REMAIN_RB" "$REMAIN_CRB" | sed '/^$/d')
RCOUNT=$(printf '%s' "$REMAIN" | grep -c . || true)

if [ "${RCOUNT:-0}" -eq 0 ]; then
  log "SUCCESS: all bindings now on '$PRIMARY_AFFINITY'"
  exit 0
fi

log "still pinned outside '$PRIMARY_AFFINITY' ($RCOUNT):"
printf '%s\n' "$REMAIN" | sed 's/^/    /'

# Nothing moved at all -> surface as a failed Job so it alerts.
if [ "$RCOUNT" -ge "$COUNT" ]; then
  log "ERROR: no binding moved. Check scheduler logs and primary capacity."
  exit 1
fi

log "partial failback; remainder will be retried next run"
exit 0
