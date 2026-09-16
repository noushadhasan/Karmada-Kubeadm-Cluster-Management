# Production Failover Hardening

This document covers the full active/passive setup actually used in **production** to optimize cloud cost: keep the workload on a single primary cluster by default, fail it over to the backup cluster automatically when the primary goes down, and — just as importantly — fail it **back** to the primary once it recovers, instead of leaving it stranded (and billed) on the backup.

Cluster names used in this environment:

- `cluster-1` — **primary**, runs the workload day-to-day.
- `cluster-2` — **backup**, only used while the primary is unhealthy.

---

## Production PropagationPolicy

```yaml
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: default-resources-active-passive
  namespace: production

spec:
  conflictResolution: Overwrite
  propagateDeps: true

  resourceSelectors:
    - apiVersion: apps/v1
      kind: Deployment

    - apiVersion: v1
      kind: Service

    - apiVersion: v1
      kind: Secret

    - apiVersion: networking.k8s.io/v1
      kind: Ingress

  placement:
    clusterAffinities:

      # Priority 1 - PRIMARY
      - affinityName: primary-k2
        clusterNames:
          - cluster-1

      # Priority 2 - BACKUP
      - affinityName: secondary-k1
        clusterNames:
          - cluster-2

  failover:
    cluster:
      purgeMode: Gracefully
```

`clusterAffinities` defines an ordered failover chain: Karmada schedules to `primary-k2` (`cluster-1`) first, and only falls back to `secondary-k1` (`cluster-2`) once the primary cluster stops satisfying the placement — e.g. it's tainted out by the [ClusterTaintPolicy](#production-clustertaintpolicy) below. `failover.cluster.purgeMode: Gracefully` ensures resources are gracefully removed from a failed-over-from cluster instead of being deleted abruptly.

Apply it, then verify:

```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config apply -f propagationPolicy.yaml
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get propagationpolicy
```

## Production ClusterTaintPolicy

```yaml
apiVersion: policy.karmada.io/v1alpha1
kind: ClusterTaintPolicy
metadata:
  name: automatic-cluster-failover

spec:
  targetClusters:
    clusterNames:
      - cluster-1
      - cluster-2

  addOnConditions:
    - conditionType: Ready
      operator: NotIn
      statusValues:
        - "True"

  removeOnConditions:
    - conditionType: Ready
      operator: In
      statusValues:
        - "True"

  taints:
    - key: failover.karmada.io/unhealthy
      effect: NoExecute
```

When a target cluster's `Ready` condition becomes anything other than `"True"`, Karmada adds the `failover.karmada.io/unhealthy` taint with effect `NoExecute`, which evicts scheduled resources from that cluster. Combined with the `clusterAffinities` failover chain above, this drives the active-passive behavior: if `cluster-1` (primary) goes unhealthy, resources fail over to `cluster-2` (backup). Once the cluster's `Ready` condition returns to `"True"`, the taint is automatically removed.

Apply it, then verify:

```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config apply -f clusterTaintPolicy.yaml
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get clustertaintpolicy
```

### Cleanup / removing the policies

```bash
# PropagationPolicy
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config -n production delete propagationpolicy default-resources-active-passive

# Also delete the corresponding resourcebinding it left behind (e.g. Ingress resources)
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config -n production get resourcebinding
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config -n production delete resourcebinding example-ingress

# ClusterTaintPolicy
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config delete clustertaintpolicy automatic-cluster-failover
```

---

## Enable Failover on the Controller Manager

Applying the policies above is not enough on its own — Karmada only evicts workloads off a `NoExecute`-tainted cluster (and reschedules them per `clusterAffinities`) when the `Failover` feature gate and no-execute taint eviction are explicitly enabled on `karmada-controller-manager`. Without this, `ClusterTaintPolicy` will still add/remove the taint on health changes, but nothing will actually move.

```bash
kubectl patch deploy karmada-controller-manager -n karmada-system --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"--feature-gates=Failover=true"},{"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"--enable-no-execute-taint-eviction=true"}]'
```

This appends two flags to the container command:

- `--feature-gates=Failover=true` — turns on Karmada's failover feature gate.
- `--enable-no-execute-taint-eviction=true` — lets the `NoExecute` taint from `ClusterTaintPolicy` actually evict and reschedule resources off the tainted cluster, instead of just being recorded.

> **Note:** this patch edits the live Deployment object directly rather than a tracked manifest, so it will be silently dropped if `karmada-controller-manager` is ever redeployed/upgraded from its original install source (Helm, the `karmadactl init` manifests, GitOps, etc.). Re-run the patch after any such redeploy, or wrap it in a cron/CI job that re-asserts it so the flags survive reconciliation.

## Fix the Rollout Deadlock

Patching the container command triggers a rolling update of `karmada-controller-manager`. With the default rollout strategy, this deployment can deadlock — the new pod can't start until the old one is gone, but the old one won't terminate first. Force a recreate-before-create rollout instead:

```bash
kubectl patch deploy karmada-controller-manager -n karmada-system --type=merge -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
```

`maxSurge: 0` stops Kubernetes from trying to bring up a new pod alongside the old one, and `maxUnavailable: 1` allows the old pod to be terminated first, unblocking the rollout.

## Verify

```bash
kubectl get pods -n karmada-system -l app=karmada-controller-manager
```

Confirm the new `karmada-controller-manager` pod is `Running` / `1/1 Ready` before relying on failover behavior.

---

## Automatic Fail-Back to the Primary

This is the part that actually saves cloud cost — resources shouldn't stay parked on the backup cluster after a recovery. It's also the part Karmada does **not** do for you by default:

1. `cluster-1` goes `NotReady` → `ClusterTaintPolicy` taints it `failover.karmada.io/unhealthy:NoExecute` → the controller-manager (with `Failover`/`enable-no-execute-taint-eviction` on) evicts the workloads and reschedules them onto `cluster-2` per the `clusterAffinities` backup priority.
2. `cluster-1` becomes `Ready` again → the taint is automatically removed by `ClusterTaintPolicy`'s `removeOnConditions`.
3. **Nothing reschedules the workload back on its own.** Karmada's scheduler walks `clusterAffinities` **forward only**, starting from `status.schedulerObservingAffinityName` on the (Cluster)ResourceBinding. Once that field is set to the backup affinity (e.g. `secondary-k1`), it stays there — Karmada never clears it itself, so every future scheduling pass starts from the backup, not from the top of the list. `WorkloadRebalancer` doesn't fix this either: it only sets `spec.rescheduleTriggeredAt` to force a re-schedule, it doesn't clear the observed affinity, so a rebalance still resolves back to the backup. Left alone, the workload stays on `cluster-2` indefinitely even though `cluster-1` is healthy again.

To actually force fail-back, this environment runs [`failback.sh`](../failback.sh) on a **5-minute CronJob**. It:

- Gates on the primary being `Ready`, untainted, and stable for a settle window (`SETTLE_MINUTES`, default 15m) — so it doesn't fail back into a cluster that's still flapping.
- Finds every `ResourceBinding`/`ClusterResourceBinding` whose `status.schedulerObservingAffinityName` is set to anything other than the primary affinity (`primary-k2`).
- For each one, patches `status.schedulerObservingAffinityName` to `""` (clearing the pin) and then patches `spec.rescheduleTriggeredAt` (forcing Karmada to re-run scheduling) — with the observed affinity cleared, the scheduler walks `clusterAffinities` from index 0 again and lands back on `cluster-1`.
- Processes in batches (`BATCH_SIZE`, `BATCH_PAUSE`) with a `MAX_PER_RUN` cap, and verifies afterward how many bindings are still off-primary, failing the Job (so it alerts) if nothing moved at all.
- Has a kill switch (`ENABLED=false`) and a `DRY_RUN=1` mode that only logs what it would do.

### Two API servers, two RBAC surfaces

The CronJob itself runs on **k3s** (the host Karmada's control plane runs on), but the script talks to the **Karmada API server**, not the k3s API — so it needs its own ServiceAccount/RBAC/token on the Karmada side, wrapped into a kubeconfig Secret that gets mounted into the Job on the k3s side. Sequential install, no test jobs — each step below says which API server it targets.

Prerequisite: `failback.sh` already exists on the host, e.g. at `/home/ubuntu/karmada-failback/failback.sh`.

**Step 1 — Point at the Karmada control plane**

```bash
export KUBECONFIG=/etc/karmada/karmada-apiserver.config
```

**Step 2 — ServiceAccount (Karmada)**

```bash
kubectl create sa karmada-failback -n karmada-system
```

**Step 3 — ClusterRole (Karmada)**

```bash
echo '{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRole","metadata":{"name":"karmada-failback"},"rules":[{"apiGroups":["cluster.karmada.io"],"resources":["clusters"],"verbs":["get","list"]},{"apiGroups":["work.karmada.io"],"resources":["resourcebindings","clusterresourcebindings"],"verbs":["get","list","patch"]},{"apiGroups":["work.karmada.io"],"resources":["resourcebindings/status","clusterresourcebindings/status"],"verbs":["get","patch"]}]}' | kubectl apply -f -
```

**Step 4 — ClusterRoleBinding (Karmada)**

```bash
echo '{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"ClusterRoleBinding","metadata":{"name":"karmada-failback"},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"karmada-failback"},"subjects":[{"kind":"ServiceAccount","name":"karmada-failback","namespace":"karmada-system"}]}' | kubectl apply -f -
```

**Step 5 — Non-expiring SA token (Karmada)**

```bash
echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"karmada-failback-token","namespace":"karmada-system","annotations":{"kubernetes.io/service-account.name":"karmada-failback"}},"type":"kubernetes.io/service-account-token"}' | kubectl apply -f -
```

**Step 6 — Confirm the token was populated (Karmada)**

```bash
kubectl get secret karmada-failback-token -n karmada-system -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}'
```

Must print `ca.crt namespace token`. If empty, wait a few seconds and re-run — the token controller fills it asynchronously.

**Step 7 — Stop using the Karmada kubeconfig**

```bash
unset KUBECONFIG
```

Everything from here targets k3s.

**Step 8 — Generate the kubeconfig Secret into k3s**

Reads the token from Karmada, writes the Secret into k3s:

```bash
KC=/etc/karmada/karmada-apiserver.config
CA=$(kubectl --kubeconfig=$KC get secret karmada-failback-token -n karmada-system -o jsonpath='{.data.ca\.crt}')
TOK=$(kubectl --kubeconfig=$KC get secret karmada-failback-token -n karmada-system -o jsonpath='{.data.token}' | base64 -d)
F=$(mktemp); chmod 600 $F
printf '%s' '{"apiVersion":"v1","kind":"Config","current-context":"karmada","clusters":[{"name":"karmada","cluster":{"server":"https://karmada-apiserver.karmada-system.svc.cluster.local:5443","certificate-authority-data":"'"$CA"'"}}],"users":[{"name":"failback","user":{"token":"'"$TOK"'"}}],"contexts":[{"name":"karmada","context":{"cluster":"karmada","user":"failback"}}]}' > $F
kubectl create secret generic karmada-failback-kubeconfig -n karmada-system --from-file=karmada.config=$F --dry-run=client -o json | kubectl apply -f -
rm -f $F
```

**Step 9 — Script ConfigMap (k3s)**

```bash
kubectl create configmap karmada-failback-script -n karmada-system --from-file=failback.sh=/home/ubuntu/karmada-failback/failback.sh --dry-run=client -o json | kubectl apply -f -
```

**Step 10 — Config ConfigMap (k3s)**

```bash
kubectl create configmap karmada-failback-config -n karmada-system \
  --from-literal=ENABLED=true \
  --from-literal=DRY_RUN=0 \
  --from-literal=PRIMARY_CLUSTER=cluster-1 \
  --from-literal=PRIMARY_AFFINITY=primary-k2 \
  --from-literal=SETTLE_MINUTES=15 \
  --from-literal=BATCH_SIZE=20 \
  --from-literal=BATCH_PAUSE=15 \
  --from-literal=MAX_PER_RUN=50 \
  --dry-run=client -o json | kubectl apply -f -
```

**Step 11 — CronJob (k3s)**

```bash
echo '{"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"karmada-failback","namespace":"karmada-system"},"spec":{"schedule":"*/5 * * * *","suspend":false,"concurrencyPolicy":"Forbid","successfulJobsHistoryLimit":3,"failedJobsHistoryLimit":3,"startingDeadlineSeconds":120,"jobTemplate":{"spec":{"backoffLimit":0,"ttlSecondsAfterFinished":3600,"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"failback","image":"docker.io/rancher/klipper-helm:v0.13.3-build20260727","imagePullPolicy":"IfNotPresent","command":["/bin/bash","/opt/failback/failback.sh"],"envFrom":[{"configMapRef":{"name":"karmada-failback-config"}}],"resources":{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"memory":"256Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"script","mountPath":"/opt/failback","readOnly":true},{"name":"kubeconfig","mountPath":"/etc/karmada/config","readOnly":true},{"name":"kubectl","mountPath":"/usr/local/bin/kubectl","readOnly":true}]}],"volumes":[{"name":"script","configMap":{"name":"karmada-failback-script","defaultMode":493}},{"name":"kubeconfig","secret":{"secretName":"karmada-failback-kubeconfig","defaultMode":292}},{"name":"kubectl","hostPath":{"path":"/usr/local/bin/kubectl","type":"File"}}]}}}}}}' | kubectl apply -f -
```

**Step 12 — Verify it runs (k3s)**

Wait for the next 5-minute boundary, then:

```bash
kubectl logs -n karmada-system -l job-name --tail=20 --prefix
```

Expect `primary cluster-1: Ready, untainted, stable for Nm -> proceeding`, followed by `nothing to do` once everything is already back home.

### Staged vs. live install

Steps 10–11 above install it **live**: `ENABLED=true`/`DRY_RUN=0` in the ConfigMap and `"suspend":false` in the CronJob mean it acts from the very first tick. To stage it instead — observe logs for a while before it patches anything — use `ENABLED=false`/`DRY_RUN=1` in step 10 and `"suspend":true` in step 11, then flip both on once you trust it.

### Kill switch

For planned maintenance on the primary (so the CronJob doesn't fight you while you intentionally drain `cluster-1`):

```bash
kubectl patch cm karmada-failback-config -n karmada-system --type=merge -p '{"data":{"ENABLED":"false"}}'
```

---

## Manual Failover Drill

To rehearse the failover/fail-back cycle without waiting for a real outage, manually taint the primary cluster:

```bash
karmadactl --kubeconfig=/etc/karmada/karmada-apiserver.config taint cluster cluster-1 failover-test:NoExecute
```

Confirm workloads move to `cluster-2`, then remove the taint to confirm they move back to `cluster-1`:

```bash
karmadactl --kubeconfig=/etc/karmada/karmada-apiserver.config taint cluster cluster-1 failover-test:NoExecute-
```

The trailing `-` after `NoExecute` is `karmadactl`'s syntax for removing a taint rather than adding one.
