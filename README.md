# 🚀 Karmada Multi-Cluster Kubernetes Deployment with HAProxy

A production-style **multi-cluster Kubernetes deployment** using **Karmada** to centrally manage multiple Kubernetes clusters and automatically distribute Kubernetes resources such as **Deployments, Services, Ingresses, Secrets, and ConfigMaps**.

This project demonstrates how to build a centralized control plane that manages multiple Kubernetes clusters while exposing applications through a single **HAProxy Load Balancer**.

---

# 📌 Project Overview

Karmada provides a single control plane to manage multiple Kubernetes clusters.

In this project I configured:

- ✅ Karmada Control Plane
- ✅ Two Kubernetes member clusters
- ✅ Cluster registration (Join Clusters)
- ✅ Resource propagation using PropagationPolicy
- ✅ Automatic deployment distribution
- ✅ HAProxy Load Balancer
- ✅ Centralized application management

The control plane distributes workloads across both Kubernetes clusters while HAProxy exposes them through a single public endpoint. :contentReference[oaicite:1]{index=1}

---

# 🏗 Architecture

```
                    Azure DevOps / kubectl
                             │
                             ▼
                  +-----------------------+
                  |    Karmada Control    |
                  |       Plane           |
                  +-----------------------+
                     │               │
          Propagation│               │Propagation
                     ▼               ▼
          +----------------+   +----------------+
          | Kubernetes     |   | Kubernetes     |
          | Cluster 01     |   | Cluster 02     |
          +----------------+   +----------------+
                 │                    │
                 └──────────┬─────────┘
                            │
                    HAProxy Load Balancer
                            │
                        Public Internet
```

---

# 🚀 Features

- Multi-cluster Kubernetes management
- Centralized Karmada Control Plane
- Cluster Join & Unjoin
- Resource Propagation
- Deployment Synchronization
- Service Synchronization
- Ingress Synchronization
- Secret Synchronization
- ConfigMap Synchronization
- HAProxy TCP/TLS Passthrough
- High Availability Architecture
- Azure DevOps Ready

---

# 🛠 Technologies Used

- Kubernetes
- Karmada v1.15.1
- K3s
- HAProxy
- Docker
- kubectl
- karmadactl
- NGINX Ingress Controller
- Azure DevOps

---

# 📂 Resources Distributed

The following Kubernetes resources are automatically propagated to both clusters:

- Deployment
- Service
- Ingress
- ConfigMap
- Secret

using **PropagationPolicy**.

---

# 📋 Project Workflow

### 1. Create Karmada Control Plane

- Install K3s
- Install Karmada
- Configure kubeconfig
- Verify API server

---

### 2. Register Member Clusters

Join both Kubernetes clusters using:

- karmadactl join

After joining, Karmada manages both clusters from a single control plane. :contentReference[oaicite:2]{index=2}

---

### 3. Configure Propagation Policy

A PropagationPolicy is created to automatically distribute resources to both clusters.

Resources included:

- Deployment
- Service
- Ingress
- ConfigMap
- Secret

Whenever these resources are created on Karmada, they are automatically synchronized across all member clusters. :contentReference[oaicite:3]{index=3}

---

### 4. HAProxy Load Balancer

A standalone HAProxy server sits in front of both Kubernetes clusters.

Responsibilities:

- Single Public IP
- TCP/TLS Passthrough
- Health Checks
- Active-Active Load Balancing
- Active-Passive Failover
- Weighted Traffic Distribution

Supported modes:

- Round Robin
- Least Connection
- Weighted Distribution
- Backup Server (Failover)

:contentReference[oaicite:4]{index=4}

---

# 📁 Repository Structure

```
.
├── manifests/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   └── propagationPolicy.yaml
│
├── docs/
│   └── Karmada_Install_and_Configuration.pdf
│
└── README.md
```

---

# 🎯 What I Learned

During this project I gained hands-on experience with:

- Multi-cluster Kubernetes architecture
- Karmada installation and configuration
- Joining and removing Kubernetes clusters
- Resource propagation
- High Availability design
- HAProxy Layer-4 Load Balancing
- Multi-cluster application deployment
- Kubernetes networking
- Ingress management
- Centralized cluster administration

---

# 💡 Real-world Use Cases

- Multi-region Kubernetes
- Disaster Recovery
- High Availability
- Blue-Green Deployments
- Centralized Cluster Management
- Hybrid Cloud
- Edge Computing

---

# 📖 Documentation

A complete step-by-step deployment guide is included in this repository.

It covers:

- Installing Karmada
- Joining clusters
- Resource migration
- PropagationPolicy
- HAProxy configuration
- Azure DevOps integration

The guide is based on the deployment document included with this project. :contentReference[oaicite:5]{index=5}

---

# 👨‍💻 Author

**Noushad Hasan**

DevOps Engineer | Kubernetes | Docker | Terraform | Jenkins | GitOps | Karmada | HAProxy | Azure DevOps

---

⭐ If you found this project useful, consider giving it a Star.
