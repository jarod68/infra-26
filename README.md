# infra-26

Declarative, **single-node k3s** deployment for a small fleet of apps, with a
unified admin surface and a full observability stack — all reproducible on a
freshly provisioned VPS with one command.

| What          | URL                              | Namespace   |
|---------------|----------------------------------|-------------|
| photo-book    | `https://book.holtz.fr`          | `web`       |
| adminer       | `https://book.holtz.fr/db`       | `web`       |
| mine-sim      | `https://play.holtz.fr`          | `web`       |
| getaround     | `https://app.holtz.fr/getaround` | `web`       |
| Portainer     | `https://admin.holtz.fr/portainer` | `web`     |
| Grafana       | `https://admin.holtz.fr/grafana` | `monitoring`|
| Prometheus / Loki | in-cluster only              | `monitoring`|

Everything sits behind **Traefik** (k3s' bundled ingress) with **free Let's
Encrypt TLS**. The whole thing runs on one node.

---

## 1. Architecture at a glance

```
                          Internet (IPv4 + IPv6)
                                   │  :80 / :443
                                   ▼
                    ┌──────────────────────────────┐
                    │  Traefik (kube-system)        │
                    │  · Let's Encrypt (HTTP-01)    │
                    │  · http→https redirect        │
                    │  · JSON access logs → stdout  │
                    └───────┬───────────────┬───────┘
      Host / PathPrefix     │               │   cross-namespace
      ┌─────────────────────┘               └───────────────┐
      ▼                                                      ▼
┌─────────────────────── namespace: web ───────────┐  ┌── namespace: monitoring ──┐
│ photo-book ─ postgres ─ adminer ─ mine-sim        │  │ Grafana                   │
│ Portainer (cluster-admin UI)                      │  │ Prometheus + node-exporter│
│                                                   │  │  + kube-state-metrics     │
│ Secrets: app-secrets, admin-basic-auth, …         │  │ Loki + Promtail           │
└───────────────────────────────────────────────────┘  └───────────────────────────┘
        ▲ every pod's stdout                                   ▲
        └──────────── Promtail (DaemonSet) ────────────────────┘  → Loki
```

- **One node, k3s**, installed **dual-stack (IPv4 + IPv6)** so Let's Encrypt can
  answer the HTTP-01 challenge over the `AAAA` record (see §6).
- **Traefik** is the only thing exposed (`:80`/`:443`), bound on both IP families
  by k3s' service-load-balancer.
- Apps live in **`web`**, observability in **`monitoring`**, Traefik and the
  helm-controller in **`kube-system`**.
- Add-ons (Traefik config, Prometheus/Grafana/Loki) are installed through k3s'
  **helm-controller** (`HelmChart` / `HelmChartConfig` CRDs) — same mechanism for
  everything, no external Helm needed.

---

## 2. Quick start (fresh VPS)

Point DNS first: **`book.holtz.fr`, `play.holtz.fr`, `app.holtz.fr` and `admin.holtz.fr`** →
the VPS public IP, with **both `A` and `AAAA`** records (the `AAAA` matters, see
§6). Then, as root:

```bash
git clone <this-repo> infra-26 && cd infra-26
cp .env.example .env          # domains / e-mail / image tags
sudo ./bootstrap.sh           # installs k3s (dual-stack) + deploys everything
```

`bootstrap.sh` installs k3s and calls `deploy.sh`. Re-running `./deploy.sh` is an
idempotent update. Certificates are issued on the first HTTPS hit (~30 s).

> Ports **80** and **443** must be reachable (open them if `ufw`/cloud firewall
> is on). Loki/Prometheus/Grafana install **asynchronously** via the
> helm-controller — give them a few minutes (`make status-mon`).

Grab the generated passwords:

```bash
make password
# Postgres            : …
# admin basic-auth    : …   (the gate in front of admin.holtz.fr)
# Grafana (admin)     : …   (the Grafana login itself)
```

---

## 3. Deployment model

`deploy.sh` is a thin, idempotent renderer:

1. Loads `.env`, requires `DOMAIN`, `PLAY_DOMAIN`, `ADMIN_DOMAIN`, `ACME_EMAIL`,
   `PHOTO_IMAGE`, `MINESIM_IMAGE`.
2. **Generates secrets once** and reuses them on every re-run:
   - `app-secrets` → Postgres password (+ optional VAPID push keys).
   - `admin-basic-auth` (apr1 hash for Traefik) + `admin-basic-auth-plain`
     (clear text for `make password`).
   - `grafana-admin` → Grafana admin user/password.
3. Applies the Traefik `HelmChartConfig`, waits for Traefik CRDs.
4. `envsubst`-renders every manifest (only the whitelisted `${VARS}` are
   substituted — Grafana's own `$__…` / `$host` are left intact) and
   `kubectl apply`s them.

No password is ever written to a synced file; `.env` holds only domains, e-mail
and image tags.

**Config knobs (`.env`):**

| Var                | Meaning                                        |
|--------------------|------------------------------------------------|
| `DOMAIN`           | photo-book host (`/db` → adminer)              |
| `PLAY_DOMAIN`      | mine-sim host                                  |
| `APP_DOMAIN`       | small-apps host (`/getaround`)                 |
| `GETAROUND_IMAGE`  | getaround-scraper image (private Docker Hub)   |
| `DOCKERHUB_USER` / `DOCKERHUB_TOKEN` | pull credentials for the private image (read-only token) |
| `ADMIN_DOMAIN`     | admin surface (`/portainer`, `/grafana`)       |
| `ACME_EMAIL`       | Let's Encrypt account e-mail                   |
| `PHOTO_IMAGE` / `MINESIM_IMAGE` | app image tags                    |
| `MINESIM_WORKERS`  | auto = host CPU count (mine-sim cluster size)  |
| `VAPID_*`          | optional Web-Push keys for photo-book          |

---

## 4. Ingress, TLS & the admin surface

Traefik is extended in [`manifests/10-traefik-acme.yaml`](manifests/10-traefik-acme.yaml)
(a `HelmChartConfig` merged into the bundled chart):

- **Let's Encrypt** resolver via HTTP-01 on the `web` entrypoint; the ACME store
  is persisted on a PVC (`/data/acme.json`).
- Global **http→https** redirect.
- **Dual-stack** LoadBalancer service (`ipFamilies: [IPv4, IPv6]`).
- **`allowCrossNamespace: true`** — lets the admin IngressRoute (ns `web`) point
  `/grafana` at the Grafana Service in ns `monitoring`.
- **JSON access logs** on stdout, including the **`Upgrade` request header**
  (for WebSocket detection). Promtail ships these to Loki (see §5).

Routes:

| Route                                  | Backend           | Middlewares                    |
|----------------------------------------|-------------------|--------------------------------|
| `Host(book) `                          | photo-book:3000   | hsts                           |
| `Host(book) && /db`                    | adminer:8080      | hsts                           |
| `Host(play)`                           | mine-sim:3200     | hsts                           |
| `Host(app) && PathPrefix(/getaround)`  | getaround:3300    | hsts, getaround-slash, getaround-auth, getaround-strip |
| `Host(admin) && /portainer`            | portainer:9000    | admin-auth, **stripPrefix**, hsts |
| `Host(admin) && /grafana`              | grafana:80 (xns)  | admin-auth, hsts               |
| `Host(admin) && /`                     | → redirect `/grafana` | admin-auth                 |

The whole **`admin.holtz.fr`** surface is gated by **basic-auth**
(`admin-basic-auth`, password in `make password`) on top of each app's own login.
Portainer runs with `--base-url=/portainer` **and** a `stripPrefix` middleware —
it serves its routes at root but emits assets under `/portainer`.

---

## 5. Monitoring stack (namespace `monitoring`)

Three pillars, all installed as `HelmChart` CRDs in
[`manifests/80-monitoring.yaml`](manifests/80-monitoring.yaml):

| Pillar    | Component                | Source / notes                              |
|-----------|--------------------------|---------------------------------------------|
| Metrics   | **kube-prometheus-stack**| Prometheus + node-exporter + kube-state-metrics + Grafana |
| Logs      | **loki-stack**           | Loki (single-binary) + Promtail (DaemonSet) |
| Requests  | Traefik **access logs**  | JSON logs → Promtail → Loki (query layer)   |

**Grafana** is served at `admin.holtz.fr/grafana` (`serve_from_sub_path`), lands
on the **HTTP & WebSocket** dashboard at login, and has two datasources:

- **Prometheus** (default) — provisioned by kube-prometheus-stack's sidecar.
- **Loki** (uid `loki`) — provisioned by our own `loki-datasource` ConfigMap.
  > loki-stack's *own* datasource is disabled
  > (`grafana.sidecar.datasources.enabled: false`) because it ships a second
  > "Loki" marked `isDefault:true`, which collides with Prometheus and breaks
  > Grafana provisioning.

**Dashboards** ([`manifests/81-grafana-dashboards.yaml`](manifests/81-grafana-dashboards.yaml),
provisioned via the dashboards sidecar, tagged `infra26`, cross-linked by a
dropdown) — the default kube-prometheus-stack dashboards are **disabled** to keep
things focused:

- **HTTP & WebSocket** — KPIs (req/s, 4xx/s, 5xx/s, p95 latency, WS upgrades),
  request rate by status/host, WebSocket log, and the full access-log stream.
  Filterable by `Host`.
- **Resources per container** — node totals (CPU %, RAM %, disk read/write,
  restarts) + per-container CPU / memory / disk I/O.

**Log / request queries** (Loki). Traefik's stdout mixes JSON access logs with
plain startup logs, so always append `| __error__=""` after `| json`:

```logql
# all requests
{namespace="kube-system", pod=~"traefik.*"} | json | __error__=""
# only app logs
{namespace="web"}
# WebSocket handshakes (identified by the Upgrade header, not the status code)
{namespace="kube-system", pod=~"traefik.*"} | json | __error__="" | request_Upgrade=`websocket`
```

> **WebSocket note:** Traefik writes a connection's access-log line **when it
> closes**, and logs it with `DownstreamStatus: 0` (the connection is hijacked,
> so no final HTTP status is recorded). WS are therefore matched on the `Upgrade`
> header, and only appear once the socket closes.

**Single-node tuning:** Loki is configured (in `80-monitoring.yaml`) to avoid
*"too many outstanding requests"* without burning CPU — big frontend queue, no
query splitting for short ranges, low concurrency. Prometheus retention is 7d;
Alertmanager and the k3s-incompatible control-plane scrape jobs are disabled.

---

## 6. Networking & TLS (dual-stack)

k3s is installed **dual-stack** by `bootstrap.sh` (cluster/service CIDRs for both
families + `--flannel-ipv6-masq`, node IPs auto-detected). This is required
because **Let's Encrypt validates over IPv6 first when an `AAAA` record exists** —
on a single-stack cluster the HTTP-01 challenge over IPv6 fails and no cert is
issued. Dual-stack makes Traefik answer the challenge on both families.

> The CIDRs are set **at install time** and cannot be changed on a running
> cluster — switching requires `k3s-uninstall.sh` then `./bootstrap.sh`.

---

## 7. Persistence (k3s local-path, under `/var/lib/rancher/k3s/storage`)

| PVC                    | Holds                                     |
|------------------------|-------------------------------------------|
| `postgres-data`        | PostgreSQL database                       |
| `photo-book-photos`    | Original photos                           |
| `photo-book-previews`  | Preview thumbnails (cache)                |
| `photo-book-medium`    | Medium images (cache)                     |
| `mine-sim-data`        | mine-sim admin password + SQLite DB       |
| `getaround-data`       | getaround SQLite DB (zones, relevés)      |
| `portainer-data`       | Portainer database                        |
| Prometheus / Grafana / Loki | metrics, dashboards, logs (7d)       |

Resolve a PVC's host path with:

```bash
kubectl -n <ns> get pvc <name> -o jsonpath='{.spec.volumeName}' \
  | xargs -I% kubectl get pv % -o jsonpath='{.spec.local.path}{"\n"}'
```

> `k3s-uninstall.sh` **deletes all of this**. Back up first (`pg_dump`, `tar` the
> photo PVCs) before reinstalling.

---

## 8. Day-to-day

```bash
make status        # web: pods / svc / ingressroutes / pvc
make status-mon    # monitoring: pods / svc / pvc
make update        # pull :latest images and rolling-restart the apps
make deploy        # re-apply manifests after editing them
make password      # print Postgres / admin basic-auth / Grafana passwords
make logs-photo    # also: logs-mine, logs-db, logs-traefik, logs-grafana, logs-loki
```

---

## 9. Layout

```
infra-26/
├── .env.example              # domains, e-mail, image tags, optional VAPID keys
├── bootstrap.sh              # fresh VPS: install k3s (dual-stack), then deploy
├── deploy.sh                 # secrets + envsubst render + kubectl apply (idempotent)
├── Makefile                  # bootstrap / deploy / update / status / logs / password
└── manifests/
    ├── 00-namespace.yaml         # namespace: web
    ├── 10-traefik-acme.yaml      # HelmChartConfig: LE, redirect, dual-stack svc,
    │                             #   cross-namespace, JSON access logs + Upgrade header
    ├── 15-middlewares.yaml       # HSTS middleware
    ├── 30-postgres.yaml          # Deployment + PVC + Service
    ├── 35-adminer.yaml           # Deployment + Service
    ├── 40-photo-book.yaml        # Deployment + 3 PVCs + Service
    ├── 50-mine-sim.yaml          # Deployment + PVC + Service
    ├── 55-getaround.yaml         # Deployment + PVC + Service (private image)
    ├── 60-ingressroutes.yaml     # book / book/db / play routes
    ├── 70-portainer.yaml         # Portainer (--base-url) + SA/ClusterRoleBinding + PVC
    ├── 80-monitoring.yaml        # HelmCharts: kube-prometheus-stack, loki-stack
    │                             #   + Loki datasource ConfigMap
    ├── 81-grafana-dashboards.yaml# 2 provisioned dashboards (ConfigMap)
    └── 85-admin-ingress.yaml     # admin.holtz.fr: auth + /portainer + /grafana + redirect
```

---

## 10. Gotchas we hit (so you don't)

- **No cert issued** → check `kubectl -n kube-system logs deploy/traefik | grep -i acme`.
  If it validates over an IPv6 address and 404s, the cluster is single-stack:
  reinstall dual-stack (§6). If it's `Connection refused`, ports 80/443 aren't
  reachable.
- **Grafana `CrashLoopBackOff`** with *"only one datasource … default"* → a second
  default datasource (loki-stack's) — disabled here via
  `grafana.sidecar.datasources.enabled: false`.
- **Datasource missing after adding a ConfigMap** → Grafana reads provisioning at
  startup: `kubectl -n monitoring rollout restart deploy/grafana`.
- **KPIs show `not a valid duration string: $__rate_interval`** → this Grafana
  build doesn't interpolate built-in interval macros in provisioned queries; the
  dashboards use fixed windows (`[5m]`, `[1h]`) instead.
- **`pipeline error: JSONParserErr`** → Traefik's non-access-log lines aren't
  JSON; append `| __error__=""` after `| json`.
- **`admin.holtz.fr/portainer` 404** → Portainer needs both `--base-url=/portainer`
  *and* the `stripPrefix` middleware.
- **Loki *"too many outstanding requests"*** → single-node query tuning in
  `80-monitoring.yaml`.
