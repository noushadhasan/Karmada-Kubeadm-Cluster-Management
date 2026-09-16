# Install Docker & kubectl 
On the Karmada VM, update the system, install base packages, then Docker and kubectl:
```bash
sudo apt update 
sudo apt install -y curl wget git vim net-tools \ 
     ca-certificates gnupg lsb-release 
 
curl -fsSL https://get.docker.com | sh 
docker version
```

# Download and install the kubectl binary: 
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s \ 
  https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" 
 
chmod +x kubectl 
sudo mv kubectl /usr/local/bin/ 
kubectl version --client 
```
# Install the Karmada CLI
```bash
wget https://github.com/karmada-io/karmada/releases/\ 
download/v1.18.0/karmadactl-linux-amd64.tgz 
 
tar -zxvf karmadactl-linux-amd64.tgz 
sudo mv karmadactl /usr/local/bin/ 
karmadactl version
```
# Create the Karmada Control Plane
# Install K3s
```bash
curl -sfL https://get.k3s.io | sh - 

#Set the kubeconfig

mkdir -p ~/.kube 
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 
sed -i 's/127.0.0.1/<karmada master ip>/g' ~/.kube/config 
chmod 600 ~/.kube/config 
kubectl get nodes
```
# Initialize Karmada Control Panel
```bash
sudo karmadactl init --kubeconfig=/home/ubuntu/.kube/config --crds=https://github.com/karmada-io/karmada/releases/download/v1.18.0/crds.tar.gz
sudo ls -lah /etc/karmada/
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get clusters
kubectl get pods -n karmada-system -o wide
```
# Karmada API Check:
```bash
sudo kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config cluster-info

sudo kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get namespaces
```

# Find the Karmada kubeconfig
```bash
ls -lah /etc/karmada/ 
kubectl --kubeconfig=/etc/karmada/karmada-apiserver.config get clusters 
 
# check whether the karmada-api svc is NodePort 
kubectl get svc -n karmada-system 
```
