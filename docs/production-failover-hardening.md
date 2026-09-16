# Production Failover Hardening

The [PropagationPolicy](propagation-policy.md) and [ClusterTaintPolicy](propagation-policy.md#create-a-clustertaintpolicy) guide covers the generic active/passive setup. This document covers what was additionally required to run that setup in **production** to actually optimize cloud cost: keep the workload on a single primary cluster by default, fail it over to the backup cluster automatically when the primary goes down, and — just as importantly — fail it **back** to the primary automatically once it recovers, instead of leaving it stranded (and billed) on the backup.

Cluster names used in this environment:

- `projukti-cluster` — **primary**, runs the workload day-to-day.
- `aks-combined-cluster` — **backup**, only used while the primary is unhealthy.

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
          - projukti-cluster

      # Priority 2 - BACKUP
      - affinityName: secondary-k1
        clusterNames:
          - aks-combined-cluster

  failover:
    cluster:
      purgeMode: Gracefully
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
      - projukti-cluster
      - aks-combined-cluster

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

Apply both the same way as in the [Propagation Policy guide](propagation-policy.md):

```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config apply -f propagationPolicy.yaml
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config apply -f clusterTaintPolicy.yaml
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

This is what actually saves cloud cost — resources don't stay parked on the backup cluster after a recovery:

1. `projukti-cluster` goes `NotReady` → `ClusterTaintPolicy` taints it `failover.karmada.io/unhealthy:NoExecute` → the controller-manager (with `Failover`/`enable-no-execute-taint-eviction` on) evicts the workloads and reschedules them onto `aks-combined-cluster` per the `clusterAffinities` backup priority.
2. `projukti-cluster` becomes `Ready` again → the taint is automatically removed by `ClusterTaintPolicy`'s `removeOnConditions`.
3. Because `clusterAffinities` always prefers the Priority 1 entry (`projukti-cluster`), Karmada reschedules the workloads back onto it automatically — no manual re-propagation needed, and `aks-combined-cluster` goes back to being idle standby capacity.

This bypasses Karmada's non-failover default (schedule once, stay put) and turns the pair into a true self-healing active/passive setup.

---

## Manual Failover Drill

To rehearse the failover/fail-back cycle without waiting for a real outage, manually taint the primary cluster:

```bash
karmadactl --kubeconfig=/etc/karmada/karmada-apiserver.config taint cluster projukti-cluster failover-test:NoExecute
```

Confirm workloads move to `aks-combined-cluster`, then remove the taint to confirm they move back to `projukti-cluster`:

```bash
karmadactl --kubeconfig=/etc/karmada/karmada-apiserver.config taint cluster projukti-cluster failover-test:NoExecute-
```

The trailing `-` after `NoExecute` is `karmadactl`'s syntax for removing a taint rather than adding one.
