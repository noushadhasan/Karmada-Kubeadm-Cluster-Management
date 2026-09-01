A PropagationPolicy tells Karmada which resources to distribute and to which clusters. 
# Create a PropagationPolicy 
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

    - apiVersion: networking.k8s.io/v1
      kind: Ingress

    - apiVersion: v1
      kind: ConfigMap

    - apiVersion: v1
      kind: Secret

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
`clusterAffinities` defines an ordered failover chain: Karmada schedules to `primary-k2` first, and only falls back to `secondary-k1` once the primary cluster stops satisfying the placement (e.g. it is tainted out, see [ClusterTaintPolicy](#create-a-clustertaintpolicy) below). `failover.cluster.purgeMode: Gracefully` ensures resources are gracefully removed from a failed-over-from cluster instead of being deleted abruptly.

# Apply the policy on the Karmada cluster, then verify: 
```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config apply -f propagationPolicy.yaml 
 
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get propagationPolicy 
```
# To Delete propagationpolicy

```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config -n production delete propagationpolicy default-resources-active-passive
```
* Also Delete corresponfing resourcebinding: (Ex: Ingress resources)
```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config -n production get resourcebinding 
kubectl  --kubeconfig=/etc/karmada/karmada-apiserver.config -n production delete resourcebinding example-ingress
```

---

# Create a ClusterTaintPolicy
A ClusterTaintPolicy tells Karmada when to automatically taint a member cluster as unhealthy (and when to remove that taint), so that resource placement can react to cluster health without manual intervention.

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
When a target cluster's `Ready` condition becomes anything other than `"True"`, Karmada adds the `failover.karmada.io/unhealthy` taint with effect `NoExecute`, which evicts scheduled resources from that cluster. Combined with the `clusterAffinities` failover chain in the PropagationPolicy above, this drives the active-passive behavior: if `cluster-1` (primary) goes unhealthy, resources fail over to `cluster-2` (backup). Once the cluster's `Ready` condition returns to `"True"`, the taint is automatically removed.

# Apply the policy on the Karmada cluster, then verify:
```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config apply -f clusterTaintPolicy.yaml

kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get clustertaintpolicy
```
# To Delete clustertaintpolicy
```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config delete clustertaintpolicy automatic-cluster-failover
```