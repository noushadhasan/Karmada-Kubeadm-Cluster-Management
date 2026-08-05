# Copy the Cluster Kubeconfigs 
Copy each member cluster's kubeconfig onto the Karmada VM
* From cluster-1 master:
```bash
cd /home/ubuntu 
scp .kube/config root@<karmada ip>:/home/ubuntu/cluster-1.config
```
* From cluster-2 master
```bash
cd /home/ubuntu 
scp .kube/config root@<karmada ip>:/home/ubuntu/cluster-2.config
```
# Join the Clusters to Karmada
```bash
karmadactl join cluster-1 \ 
  --cluster-kubeconfig=/home/ubuntu/cluster-1.config \ 
  --kubeconfig=/etc/karmada/karmada-apiserver.config 
```
```bash
karmadactl join cluster-2 \ 
  --cluster-kubeconfig=/home/ubuntu/cluster-2.config \ 
  --kubeconfig=/etc/karmada/karmada-apiserver.config 
```
* Check the clusters after joining 
 ```bash
 kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get clusters
 ```

 # To unjoin the Cluster: 
 ```bash
 kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get clusters 
 
 * get the target cluster context
   kubectl config get-contexts --kubeconfig=/home/ibos/new-cluster.config 
 * Unjoin the cluster 
 ```bash
 karmadactl unjoin cluster-2 \ 
  --cluster-kubeconfig=/home/ubuntu./cluste-2.config \ 
  --cluster-context=kubernetes-admin@kubernetes \ 
  --kubeconfig=/etc/karmada/karmada-apiserver.config 
  ```
  