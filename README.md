# Karmada Multi-Cluster Kubernetes Deployment with Active/Passive Failover

A production-style **multi-cluster Kubernetes deployment** using **Karmada** to centrally manage multiple Kubernetes clusters and automatically distribute Kubernetes resources such as **Deployments, Services, Ingresses, Secrets, and ConfigMaps**.

This project builds a centralized control plane that manages multiple Kubernetes clusters, automatically fails workloads over between clusters using Karmada's `ClusterAffinities` and `ClusterTaintPolicy`, fails them back once the primary recovers, and exposes applications through either a **Cloudflare Load Balancer** (recommended — no load-balancer infrastructure of your own) or a self-hosted **HAProxy Load Balancer**.

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

The control plane runs workloads on the primary cluster, automatically fails them over to the standby cluster if the primary becomes unhealthy, and fails them back once it recovers — while Cloudflare or HAProxy exposes them through a single public endpoint.

---

# 🏗 Architecture

### Active/Passive Failover & Fail-Back Cycle

![Karmada Failover and Fail-Back](assets/karmada-failover-failback.gif)

This is the actual cycle running in production. The k3s-hosted Karmada control plane (`karmada-apiserver`, `karmada-scheduler`, `karmada-controller-manager` with `TaintManager` active) keeps workloads on `cluster-1` (**PRIMARY**, affinity `primary-k2`) while it is `Ready`.

- **Failover:** if `cluster-1` goes unhealthy, `ClusterTaintPolicy` taints it `NoExecute` and workloads are rescheduled to `cluster-2` (**SECONDARY**, affinity `secondary-k1`).
- **Fail-back:** once the primary is `Ready`, untainted, and stable for the settle window, the `failback` CronJob (`*/5 * * * *`) moves the workloads back to `cluster-1`.

See [Production Failover Hardening](docs/production-failover-hardening.md) for exactly how both directions work.

### Full Deployment Pipeline

![Karmada Deployment Lifecycle](assets/karmada-deployment-lifecycle.gif)

The wider pipeline this cycle feeds into: CI/CD → Karmada Control Plane → PropagationPolicy → member clusters → edge Load Balancer (Cloudflare or HAProxy) → DNS → users.

### Active/Active High Availability: Dual-Cluster Propagation with HAProxy (Optional)

![Karmada HAProxy Architecture](assets/karmada-haproxy-blog-architecture.gif)

The original design: Karmada auto-propagates resources to both member clusters as an active/active, highly-available pair, with application traffic arriving through a self-hosted **HAProxy** load balancer in front of both clusters' Ingress controllers. It predates the `ClusterAffinities`/`ClusterTaintPolicy` active/passive failover and the fail-back CronJob shown above, and is kept here as the HAProxy-based alternative to the Cloudflare design.

---

# 🚀 Features

- Multi-cluster Kubernetes management
- Centralized Karmada Control Plane
- Cluster Join & Unjoin
- Resource Propagation
- Deployment, Service, Ingress, Secret and ConfigMap synchronization
- Active/Passive failover with `ClusterAffinities`
- Automatic unhealthy-cluster tainting with `ClusterTaintPolicy`
- Automatic fail-back to the primary cluster via CronJob
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

The following Kubernetes resources are automatically propagated by Karmada using **PropagationPolicy**, running on whichever cluster is currently active per the `ClusterAffinities` failover chain:

- Deployment
- Service
- Ingress
- ConfigMap
- Secret

---

# 📋 Project Workflow

### 1. Create Karmada Control Plane

- Install K3s
- Install Karmada
- Configure kubeconfig
- Verify API server

### 2. Register Member Clusters

Join both Kubernetes clusters using `karmadactl join`. After joining, Karmada manages both clusters from a single control plane.

### 3. Configure Propagation Policy

A PropagationPolicy distributes Deployments, Services, Ingresses, ConfigMaps and Secrets to the member clusters. Whenever these resources are created on Karmada, they are automatically synchronized to the selected cluster(s).

### 4. Active/Passive Failover (ClusterAffinities + ClusterTaintPolicy)

Instead of scheduling to both clusters at once, the PropagationPolicy uses `placement.clusterAffinities` to define an ordered failover chain:

- `cluster-1` is scheduled first as the **Primary**.
- `cluster-2` is only used as the **Backup** once the primary stops satisfying placement.

A companion `ClusterTaintPolicy` watches each member cluster's `Ready` condition and automatically:

- Taints a cluster as `failover.karmada.io/unhealthy` (`NoExecute`) when it goes unhealthy, evicting workloads from it.
- Removes the taint once the cluster recovers.

A `failback` CronJob then returns workloads to the primary once it has been healthy for the settle window. Together these drive unattended failover and fail-back — no manual intervention required.

### 5. Load Balancer / Traffic Exposure

Two options are documented for exposing the active cluster to the internet:

- **Cloudflare Load Balancer (recommended)** — a managed Layer-7 load balancer. Nothing to run or patch yourself; DNS, health checks and failover all live in one dashboard. This is the option used in production for this project.
- **HAProxy** — a self-hosted Layer-4 (TCP/TLS passthrough) load balancer, for keeping the entire path on your own infrastructure.

#### Cloudflare Load Balancer (Recommended)

Cloudflare's Load Balancer fronts the two clusters directly:

- **Primary Pool** (`Cluster-1-POOL`) and **Backup Pool** (`Cluster-2-POOL`), each pointing at one cluster's Ingress public IP on port 443.
- **Traffic Steering: Off**, so Cloudflare uses pool priority order (Primary → Backup) rather than latency/geo-based steering.
- An **HTTPS health monitor** checking `/health` or `/healthz` for a `200` response, so failover reacts to application health, not just port reachability.
- **Zero Downtime Failover** enabled to retry failed requests against the next healthy pool.

Full failover flow: Karmada detects the primary cluster is down → `ClusterTaintPolicy` taints it → workloads are rescheduled to `cluster-2` → the app becomes healthy there → the Cloudflare HTTPS monitor marks the backup pool healthy → traffic moves to `cluster-2`.

See [Cloudflare Load Balancer Configuration](docs/cloudflare-karmada-lb.md) and the [dashboard walkthrough](docs/cloudflare-lb-pool-setup.md) for the full pool, monitor, and DNS setup.

#### HAProxy Load Balancer

A standalone HAProxy server sits in front of both Kubernetes clusters, avoiding any dependency on a third-party load balancer.

Responsibilities:

- Single Public IP
- TCP/TLS Passthrough
- Health Checks
- Active-Active Load Balancing
- Active-Passive Failover
- Weighted Traffic Distribution

Supported modes: Round Robin, Least Connection, Weighted Distribution, Backup Server (Failover).

See [HAProxy Configuration](docs/haproxy.md) for the full setup.

---

# 🎯 What I Have Worked On

During this project I gained hands-on experience with:

- Multi-cluster Kubernetes architecture
- Karmada installation and configuration
- Joining and removing Kubernetes clusters
- Resource propagation
- Active/Passive failover and fail-back with ClusterAffinities and ClusterTaintPolicy
- High Availability design
- HAProxy Layer-4 Load Balancing
- Cloudflare Layer-7 Load Balancing and pool/health-monitor configuration
- Multi-cluster application deployment
- Kubernetes networking and Ingress management
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
| [Installation](docs/Karmada-installation.md) | Install Docker, kubectl, K3s and Karmada |
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
