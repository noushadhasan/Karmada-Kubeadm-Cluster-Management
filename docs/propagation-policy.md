A PropagationPolicy tells Karmada which resources to distribute and to which clusters. 
# Create a PropagationPolicy 
```bash
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: default-apps-to-both-clusters
  namespace: production
spec:
  conflictResolution: Overwrite
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
    clusterAffinity:
      clusterNames:
        - cluster-1
        - cluster-2
```
# Apply the policy on the Karmada cluster, then verify: 
```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config apply -f propagationPolicy.yaml 
 
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get propagationPolicy 
```
# To Delete propagationpolicy

```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config -n production delete propagationpolicy default-apps-to-both-clusters
```
* Also Delete corresponfing resourcebinding: (Ex: Ingress resources)
```bash
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config -n production get resourcebinding 
kubectl  --kubeconfig=/etc/karmada/karmada-apiserver.config -n production delete resourcebinding example-ingress
```