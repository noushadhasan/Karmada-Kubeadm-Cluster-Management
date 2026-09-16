# Cloudflare Load Balancer — Dashboard Pool Setup (Step by Step)

This is the hands-on dashboard walkthrough for the **Pools** step of Cloudflare's load balancer wizard (`Hostname > Pools > Monitors > Traffic Steering > Custom Rules > Review`). For the conceptual design (why Traffic Steering is off, why an HTTPS monitor instead of TCP, DNS setup, etc.) see [Cloudflare Load Balancer Configuration](cloudflare-karmada-lb.md) — this doc is just "what to click."

Two endpoints are used — one per cluster's Ingress public IP — with `cluster-2` set as the fallback pool.

---

## 1. Go to the load balancer's Pools step

Dashboard path:

```text
Cloudflare Dashboard
  -> Traffic
  -> Load Balancing
  -> (your load balancer, e.g. load.yourdomain.com)
  -> Edit
  -> Pools
```

You'll land on the wizard breadcrumb: `Hostname > Pools > Monitors > Traffic Steering > Custom Rules > Review`.

## 2. Add the primary pool (cluster-1)

Click **Add Pool** and create:

```text
Pool Name:  cluster-1-POOL
Endpoint:   <cluster-1 Ingress public IP>
Port:       443
Enabled:    Yes
```

This is the pool that receives 100% of traffic while `cluster-1` is healthy — it's your **primary/active** cluster's Ingress.

## 3. Add the backup pool (cluster-2)

Click **Add Pool** again and create:

```text
Pool Name:  cluster-2-POOL
Endpoint:   <cluster-2 Ingress public IP>
Port:       443
Enabled:    Yes
```

This is the **fallback pool** — it only receives traffic once `cluster-1-POOL` is marked unhealthy by the monitor.

## 4. Set the pool order (this controls fallback priority)

In the **Endpoints in this load balancer** table, drag the pools (using the `::` handle on the left) so the order is:

```text
Order 1 — cluster-1-POOL   (Healthy)
Order 2 — cluster-2-POOL   (Healthy, standby)
```

> Cloudflare fails over top-to-bottom: traffic always lands on Pool #1 until it's marked unhealthy, then moves to Pool #2. **Do not put the backup pool first.** In the "Edit public load balancer" screen this looks like:
>
> | Order | Health  | Pool Name       | Endpoints  |
> |-------|---------|-----------------|------------|
> | 1     | Healthy | `cluster-1-POOL`| 1 endpoint |
> | 2     | Healthy | `cluster-2-POOL`| 1 endpoint |

Leave **Shedding** and **Proximity** disabled for both pools — this setup uses simple priority failover, not traffic shaping.

## 5. Continue through the remaining wizard steps

- **Monitors** — attach an HTTPS monitor (not TCP) as described in [Health Monitor Configuration](cloudflare-karmada-lb.md#health-monitor-configuration).
- **Traffic Steering** — set to `Off` so pool order (not latency/geo) decides failover, per [Traffic Steering](cloudflare-karmada-lb.md#traffic-steering).
- **Custom Rules** — leave empty unless you have a reason to override routing for specific paths/headers.
- **Review** — confirm both pools, the monitor, and `Traffic Steering: Off`, then save.

## 6. Verify

```bash
# Confirm both pools are healthy
curl -vk --resolve <your-domain>:443:<cluster-1 ingress ip> https://<your-domain>
curl -vk --resolve <your-domain>:443:<cluster-2 ingress ip> https://<your-domain>
```

In the dashboard, both pools should show **Healthy**, with `cluster-1-POOL` at Order 1 taking live traffic and `cluster-2-POOL` at Order 2 sitting idle until Karmada's [ClusterTaintPolicy](propagation-policy.md#create-a-clustertaintpolicy) fails workloads over to it — see [Production Failover Hardening](production-failover-hardening.md) for how that failover (and automatic fail-back) is driven from the Karmada side.

---

> **Note on the screenshot above:** I don't have a way to record an actual screen-capture GIF of clicking through this wizard from here. If you want an animated walkthrough alongside this doc, record one (e.g. with ScreenToGif or Loom) and drop it in `docs/` — for example `docs/cloudflare-lb-setup-flow.gif` — and I can wire it into this page.
