# Karmada Multi-Cluster Kubernetes Deployment with Active/Passive Failover

A production-style **multi-cluster Kubernetes deployment** using **Karmada** to centrally manage multiple Kubernetes clusters and automatically distribute Kubernetes resources such as **Deployments, Services, Ingresses, Secrets, and ConfigMaps**.

This project demonstrates how to build a centralized control plane that manages multiple Kubernetes clusters, fails workloads over automatically between clusters using Karmada's `ClusterAffinities` and `ClusterTaintPolicy`, and exposes applications through either a self-hosted **HAProxy Load Balancer** or a **Cloudflare Load Balancer** — both are documented, but **Cloudflare is the simpler path for this project** since it needs no load-balancer infrastructure of your own.

---

# 📌 Project Overview

Karmada provides a single control plane to manage multiple Kubernetes clusters.

In this project I configured:

- ✅ Karmada Control Plane
- ✅ Two Kubernetes member clusters
- ✅ Cluster registration (Join Clusters)
- ✅ Resource propagation using PropagationPolicy
- ✅ Active/Passive failover using ClusterAffinities
- ✅ Automatic cluster health tainting using ClusterTaintPolicy
- ✅ Production failover hardening (controller-manager feature gates, automatic fail-back)
- ✅ Automatic deployment distribution
- ✅ Cloudflare Load Balancer (Active/Passive pool failover) — recommended, easiest to set up
- ✅ HAProxy Load Balancer — self-hosted alternative
- ✅ Centralized application management

The control plane distributes workloads across both Kubernetes clusters, automatically failing them over to the standby cluster if the primary becomes unhealthy, while HAProxy or Cloudflare exposes them through a single public endpoint.

---

# 🏗 Architecture

### Active/Passive Failover & Fail-Back Cycle

![Karmada Active/Passive Architecture](karmada-architecture.gif)

This is the actual cycle running in production: the k3s-hosted Karmada control plane (`karmada-apiserver`, `karmada-scheduler`, `karmada-controller-manager` with `TaintManager` active) keeps workloads on `cluster-1` (**PRIMARY**, affinity `primary-k2`) while it's `Ready`. If it goes unhealthy, `ClusterTaintPolicy` taints it and workloads move to `cluster-2` (**SECONDARY**, affinity `secondary-k1`). Once the primary is `Ready`, untainted, and stable for the settle window, the `failback` CronJob (`*/5 * * * *`) forces the workloads back — see [Production Failover Hardening](docs/production-failover-hardening.md) for exactly how both directions work.

### Full Deployment Pipeline

![Architecture](docs/architecture-active-passive.svg)

The wider pipeline this cycle feeds into: CI/CD → Karmada Control Plane → PropagationPolicy → member clusters → edge Load Balancer (Cloudflare or HAProxy) → DNS → users.

### HAProxy Ingress Design (Original)

![Karmada HAProxy Architecture](karmada-haproxy-blog-architecture.gif)

This is the original design: Karmada auto-propagates resources to both member clusters to keep them in an active/active, highly-available pair, with ingress traffic for the application arriving through a self-hosted **HAProxy** load balancer sitting in front of both clusters' Ingress controllers. It predates the `ClusterAffinities`/`ClusterTaintPolicy` active-passive failover and the fail-back CronJob shown above — kept here as the HAProxy-based alternative to the Cloudflare design.

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
- Active/Passive failover with `ClusterAffinities`
- Automatic unhealthy-cluster tainting with `ClusterTaintPolicy`
- HAProxy TCP/TLS Passthrough
- Cloudflare Load Balancer (Primary/Backup pools, HTTPS health monitor)
- High Availability Architecture
- Azure DevOps Ready

---

# 🛠 Technologies Used

- Kubernetes
- Karmada v1.18.0
- K3s
- HAProxy
- Cloudflare Load Balancer
- Docker
- kubectl
- karmadactl
- NGINX Ingress Controller
- Azure DevOps

---

# 📂 Resources Distributed

The following Kubernetes resources are automatically propagated by Karmada, running on whichever cluster is currently active per the `ClusterAffinities` failover chain:

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

After joining, Karmada manages both clusters from a single control plane.

---

### 3. Configure Propagation Policy

A PropagationPolicy is created to automatically distribute resources to both clusters.

Resources included:

- Deployment
- Service
- Ingress
- ConfigMap
- Secret

Whenever these resources are created on Karmada, they are automatically synchronized across all member clusters.

---

### 4. Active/Passive Failover (ClusterAffinities + ClusterTaintPolicy)

Instead of scheduling to both clusters at once, the PropagationPolicy uses `placement.clusterAffinities` to define an ordered failover chain:

- `cluster-1` is scheduled first as the **Primary**.
- `cluster-2` is only used as the **Backup** once the primary stops satisfying placement.

A companion `ClusterTaintPolicy` watches each member cluster's `Ready` condition and automatically:

- Taints a cluster as `failover.karmada.io/unhealthy` (`NoExecute`) when it goes unhealthy, evicting workloads from it.
- Removes the taint once the cluster recovers.

Together these drive automatic, unattended failover between clusters — no manual intervention required.

---

### 5. Load Balancer / Traffic Exposure

Two options are documented for exposing the active cluster to the internet, and this project has a working design for both — pick whichever fits your infrastructure:

- **Cloudflare Load Balancer (recommended)** — a managed Layer-7 load balancer. No load-balancer infrastructure to run or patch yourself, DNS/health-checks/failover all live in one dashboard, and it's the option actually used in production for this project because it's by far the easier one to stand up and operate.
- **HAProxy** — a self-hosted Layer-4 (TCP/TLS passthrough) load balancer, useful if you'd rather keep the entire path — including the load balancer — on your own infrastructure instead of depending on Cloudflare.

#### Cloudflare Load Balancer (Recommended)

Cloudflare's Load Balancer fronts the two clusters directly:

- **Primary Pool** (`Cluster-1-POOL`) and **Backup Pool** (`Cluster-2-POOL`), each pointing at one cluster's Ingress public IP on port 443.
- **Traffic Steering: Off**, so Cloudflare uses pool priority order (Primary → Backup) rather than latency/geo-based steering.
- An **HTTPS health monitor** (not just TCP) checking `/health` or `/healthz` with an expected `200` response, so failover reacts to application health, not just port reachability.
- **Zero Downtime Failover** enabled to retry failed requests against the next healthy pool.

Full failover flow: Karmada detects the primary cluster is down → `ClusterTaintPolicy` taints it → workloads are rescheduled to `cluster-2` → the app becomes healthy there → the Cloudflare HTTPS monitor marks the backup pool healthy → traffic moves to `cluster-2`.

See [Cloudflare Load Balancer Configuration](docs/cloudflare-karmada-lb.md) and the [dashboard walkthrough](docs/cloudflare-lb-pool-setup.md) for the full pool, monitor, and DNS setup.

#### HAProxy Load Balancer

A standalone HAProxy server sits in front of both Kubernetes clusters, useful when you want to avoid depending on a third-party load balancer entirely.

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

See [HAProxy Configuration](docs/haproxy.md) for the full setup.

---

# 🎯 What I Have Worked

During this project I gained hands-on experience with:

- Multi-cluster Kubernetes architecture
- Karmada installation and configuration
- Joining and removing Kubernetes clusters
- Resource propagation
- Active/Passive failover with ClusterAffinities and ClusterTaintPolicy
- High Availability design
- HAProxy Layer-4 Load Balancing
- Cloudflare Layer-7 Load Balancing and pool/health-monitor configuration
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

| Guide | Description |
|-------|-------------|
| [Installation](docs/installation.md) | Install Docker, kubectl, K3s and Karmada |
| [Join Clusters](docs/cluster-join.md) | Register Kubernetes clusters |
| [Production Failover Hardening](docs/production-failover-hardening.md) | PropagationPolicy, ClusterTaintPolicy, controller-manager failover feature gates, rollout deadlock fix, automatic fail-back CronJob, manual drills |
| [Karmada Configuration](docs/karmada-configuration.md) | Move workloads between clusters |
| [HAProxy](docs/haproxy.md) | Configure self-hosted Load Balancer |
| [Cloudflare Load Balancer](docs/cloudflare-karmada-lb.md) | Configure managed Active/Passive Load Balancer |
| [Cloudflare LB Pool Setup](docs/cloudflare-lb-pool-setup.md) | Step-by-step dashboard walkthrough for the Pools wizard |


---

# 👨‍💻 Author

**Noushad Hasan**

DevOps Engineer | Kubernetes | Docker | Terraform | Jenkins | GitOps | Ansible | Azure DevOps

---

⭐ If you found this project useful, consider giving it a Star.
