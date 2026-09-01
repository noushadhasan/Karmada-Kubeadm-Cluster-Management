# Cloudflare Load Balancer Architecture for Karmada Multi-Cluster Failover

## Overview

This document describes the Cloudflare Load Balancer configuration used to route production traffic between two Kubernetes clusters managed by Karmada.

The design is **Active / Passive**:

- One Kubernetes cluster serves application traffic as the **Primary / Active** cluster.
- The second Kubernetes cluster remains connected to Karmada and healthy as the **Standby / Backup** cluster.
- Karmada handles Kubernetes workload failover.
- Cloudflare Load Balancer handles external traffic failover.

The goal is to minimize infrastructure cost while still providing automatic disaster recovery.

---

## Architecture

```text
                         Internet Users
                               |
                               v
                         (Your Domain)
                               |
                               | CNAME
                               v
                    (Your LoadBalancer Domain)
                               |
                               v
                  Cloudflare Load Balancer
                               |
                     Traffic Steering: OFF
                               |
                 +-------------+-------------+
                 |                           |
                 v                           v
          Primary Pool                 Backup Pool
         Cluster-1-POOL               Cluster-2-POOL
         {publip ip}:443              {publip ip}:443
                 |                           |
                 v                           v
        Kubernetes Cluster           Kubernetes Cluster
           ACTIVE / K2                STANDBY / K1
                 |                           |
                 v                           v
        NGINX Ingress LB             NGINX Ingress LB
                 |                           |
                 v                           v
        Application running          No app in normal state
```

---

## Current Load Balancer Information

### Cloudflare Load Balancer Hostname

```text
(Your LoadBalancer Domain)
```

### Application Hostname

```text
(Your Domain)
```

### DNS Record

Create a CNAME record:

```text
Type:    CNAME
Name:    (Your Domain)
Target:  (Your LoadBalancer Domain)
Proxy:   Proxied
TTL:     Auto
```

Recommended:

```text
(Your Domain)
        |
        v
(Your LoadBalancer Domain)
```

Using Cloudflare proxy mode allows Cloudflare to perform Layer-7 HTTP/HTTPS load balancing and failover.

---

# Pool Configuration

Two pools are used.

## Pool 1 - Primary

```text
Pool Name: Cluster-1-POOL
Role: Primary / Active
Endpoint: {Public IP}
Port: 443
```

Example:

```text
Cluster-1-POOL
  |
  +-- Endpoint Name: Cluster-1-k8s
  +-- Endpoint Address: {publip ip}
  +-- Port: 443
  +-- Enabled: Yes
```

This public IP is NAT/port-forwarded to the Kubernetes NGINX Ingress LoadBalancer.

The origin was validated using:

```bash
curl -vk \
  --resolve (Your Domain):443:{publip ip} \
  https://(Your Domain)
```

Expected:

```text
HTTP/2 200
```

---

## Pool 2 - Backup

```text
Pool Name: Cluster-2-POOL
Role: Secondary / Standby
Endpoint: (Your Domain)
Port: 443
```

Example:

```text
Cluster-2-POOL
  |
  +-- Endpoint Name: Cluster-2-k8s
  +-- Endpoint Address: {publip ip}
  +-- Port: 443
  +-- Enabled: Yes
```

This public IP is also NAT/port-forwarded to the backup Kubernetes NGINX Ingress LoadBalancer.

Validate it with:

```bash
curl -vk \
  --resolve (Your Domain):443:{publip ip} \
  https://(Your Domain)
```

In the normal Active/Passive state, the standby cluster may return:

```text
HTTP/2 404
```

This is expected if Karmada has not yet scheduled the application resources there.

---

# Pool Priority

The order is important.

Configure:

```text
1. Cluster-1-k8s
2. Cluster-2-k8s
```

This means:

```text
Cluster-1-k8s healthy
    |
    v
100% traffic -> Cluster-1-pool

Cluster-1-k8s unhealthy
    |
    v
Cloudflare checks next pool
    |
    v
Cluster-2-k8s healthy
    |
    v
100% traffic -> Cluster-2-k8s-pool
```

Do not place the backup pool first.

---

# Traffic Steering

Configure:

```text
Traffic Steering: Off
```

This is intentional.

With Traffic Steering disabled, Cloudflare uses pool order as failover priority.

Desired behavior:

```text
Primary healthy
    -> use Primary

Primary unhealthy
    -> use Secondary
```

Do not use these steering modes for this Active/Passive design:

```text
Random
Dynamic
Geo
Proximity
Least Outstanding Requests
```

unless the architecture is intentionally changed to Active/Active.

---

# Endpoint Steering

Inside each pool, the endpoint steering mode can remain:

```text
Random
```

because each pool currently contains only one endpoint.

Example:

```text
Cluster-1-k8s-Pool
  +-- {publip ip}

Cluster-2-k8s-Pool
  +-- {publip ip}
```

With one endpoint per pool, endpoint steering has no practical effect.

---

# IMPORTANT: Do Not set Endpoint Host-IP Overrides


# Health Monitor Configuration

Do not use only a TCP monitor.

A TCP monitor checks whether port `443` is reachable, but it cannot determine whether the actual application is available.

Example problem:

```text
{publip ip}:443 = TCP reachable
NGINX = Running
Application = Missing
HTTP response = 404
```

A TCP monitor would still consider this healthy.

For application-aware failover, configure an HTTPS monitor.

Recommended:

```text
Type: HTTPS
Port: 443
Path: /
Expected HTTP Status: 200
Host Header: (Your Domain)
```

If the application provides a health endpoint, use it instead:

```text
Path: /health
```

or:

```text
Path: /healthz
```

Recommended production monitor:

```text
Protocol: HTTPS
Port: 443
Host: (Your Domain)
Path: /health
Expected Status: 200
Timeout: 3 seconds
Consecutive Up: 1
Consecutive Down: 1 or 2
```

# Cloudflare Session Affinity

Current configuration may use:

```text
Session Affinity: By Cloudflare cookie
Session Affinity TTL: 1800 seconds
```

This is acceptable if applications require sticky sessions.

If applications are stateless, session affinity may not be required.

For Active/Passive failover, pool health and priority are more important than session affinity.

---

# Zero Downtime Failover

Recommended:

```text
Zero Downtime Failover: Enabled
Failover Across Pools: On
```

This allows Cloudflare to retry certain origin failures against another healthy pool.

However, this does not make a cold standby instantly available.

The backup pool becomes usable only after:

```text
Karmada detects failure
    |
    v
Karmada reschedules application
    |
    v
Pods become Ready
    |
    v
Ingress returns HTTP 200
    |
    v
Cloudflare marks backup healthy
    |
    v
Traffic moves to backup
```

# Complete Failover Flow

```text
                         Users
                           |
                           v
                     (Your Domain)
                           |
                           v
                  (Your Load Balancer)
                           |
                           v
                    Cloudflare LB
                           |
               Traffic Steering OFF
                           |
               +-----------+-----------+
               |                       |
               v                       v
      Cluster-1-k8s-pool         Cluster-2-k8s-pool
          PRIMARY                  BACKUP
               |
               v
         HTTP 200 Healthy
               |
               X
          Cluster Down
               |
               +---------------------------+
                                           |
                                           v
                                       Karmada
                                           |
                                  detects primary down
                                           |
                                           v
                                 reschedules resources
                                           |
                                           v
                                     Cluster-2-k8s
                                           |
                                           v
                                      HTTP 200
                                           |
                                           v
                               Cloudflare monitor healthy
                                           |
                                           v
                               Traffic -> Cluster-2-k8s
```
