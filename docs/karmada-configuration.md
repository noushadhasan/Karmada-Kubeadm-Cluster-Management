# Direct Migration of Resources

This guide walks through migrating workloads directly from `cluster-1` to `cluster-2` without going through Karmada propagation. Resources are exported as YAML from `cluster-1`, stripped of runtime metadata (resourceVersion, UID, status, etc.) using `kubectl-neat`, and then applied as-is to `cluster-2`.

## Export resources as YAML from the cluster-1
* Run Below command on Karmada Control Plane
```bash
mkdir -p /home/ubuntu/direct-migration/default

kubectl --kubeconfig=/home/ubuntu/cluster-1.config -n default \
  get deploy,svc,ingress,configmap,secret -o yaml \
  > /home/ubuntu/direct-migration/default/resources.yaml
```

## Clean the metadata
Install kubectl-neat to strip runtime metadata:
```bash
wget https://github.com/itaysk/kubectl-neat/releases/\download/v2.0.4/kubectl-neat_linux_amd64.tar.gz

tar -xzf kubectl-neat_linux_amd64.tar.gz
chmod +x kubectl-neat
mv kubectl-neat /usr/local/bin/
```
Then clean the exported file:
```bash
kubectl neat < /home/ubuntu/direct-migration/default/resources.yaml \
  > /home/ubuntu/direct-migration/default/resources-clean.yaml
```

## Apply to the cluster-2
* Dry-run first
```bash
kubectl --kubeconfig=/home/ubuntu/cluster-2.config apply \
  -f /home/ubuntu/direct-migration/default/resources-clean.yaml \
  --dry-run=server
```
* Then apply for real
```bash
kubectl --kubeconfig=/home/ubuntu/cluster-2.config apply \
  -f /home/ubuntu/direct-migration/default/resources-clean.yaml
```

## Check the cluster-2
```bash
kubectl --kubeconfig=/home/ubuntu/cluster-2.config -n default \
  get pods,svc,ingress
```

> **Note:** `cluster-1.config` and `cluster-2.config` are kubeconfig files pointing at each cluster's API server (e.g. `https://<ip>:6443`). Replace `<ip>` with the actual cluster API server address when generating or copying these kubeconfigs.
