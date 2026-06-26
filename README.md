# infra-26

Declarative, single-node **k3s** deployment for the two apps that previously
shared a hand-rolled `docker-compose` + `deploy.sh` on the VPS:

| App         | Image                       | URL                       |
|-------------|-----------------------------|---------------------------|
| photo-book  | `jarod68/photo-book:latest` | `https://book.holtz.fr`   |
| adminer     | `adminer:latest`            | `https://book.holtz.fr/db`|
| mine-sim    | `jarod68/mine-sim:latest`   | `https://play.holtz.fr`   |

**Traefik** (k3s' bundled ingress) sits in front and obtains **free Let's Encrypt
TLS** automatically — same model as before, now declarative. PostgreSQL backs
photo-book. Everything runs on one node and is **deployable on a freshly
provisioned VPS with a single command**.

## Why this replaces `photo-book/deploy.sh`

The old script `rsync`-ed the repo to `/opt`, generated a Traefik file-provider
config, wrote a `.env` with a plaintext Postgres password, and ran the stack
under a `systemd`-managed `docker compose`. This repo externalises all of that:

- **Declarative** Kubernetes manifests instead of a 400-line bash generator.
- **Secrets** live in a Kubernetes `Secret` (Postgres password is generated once
  and never written to a synced file).
- **No Docker socket mount.** photo-book only used it for an optional admin
  “running containers” panel (already wrapped in try/catch); on k3s/containerd
  that panel is simply empty. Nothing else changes.
- One `bootstrap.sh` installs k3s and deploys both apps; re-running `deploy.sh`
  is an idempotent update.

## Quick start (fresh VPS)

Point DNS first: `book.holtz.fr` **and** `play.holtz.fr` → the VPS public IP
(A and/or AAAA). Then, as root on the VPS:

```bash
git clone <this-repo> infra-26 && cd infra-26
cp .env.example .env          # adjust domains / e-mail / image tags if needed
sudo ./bootstrap.sh           # installs k3s + deploys everything
```

That installs k3s (with its bundled Traefik, local-path storage and service
load-balancer), generates the Postgres secret, and applies all manifests.
Certificates are issued on first HTTPS hit (give it ~30 s).

> Ports **80** and **443** must be reachable (open them if a firewall such as
> `ufw` is enabled). k3s' service-load-balancer binds them on the host for Traefik.

## Day-to-day

```bash
make status        # pods / services / ingressroutes / certificate store
make update        # pull :latest images and rolling-restart the apps
make deploy        # re-apply manifests after editing them
make logs-photo    # tail photo-book   (also: logs-mine, logs-traefik, logs-db)
make password      # print the generated Postgres password
```

## Layout

```
infra-26/
├── .env.example            # domains, e-mail, image tags, optional VAPID push keys
├── bootstrap.sh            # fresh-VPS: install k3s, then deploy
├── deploy.sh               # idempotent render (envsubst) + kubectl apply
├── Makefile                # bootstrap / deploy / update / status / logs / password
└── manifests/
    ├── 00-namespace.yaml
    ├── 10-traefik-acme.yaml    # HelmChartConfig: Let's Encrypt resolver + http→https
    ├── 15-middlewares.yaml     # HSTS middleware (Traefik CRD)
    ├── 30-postgres.yaml        # Deployment + PVC + Service
    ├── 35-adminer.yaml         # Deployment + Service
    ├── 40-photo-book.yaml      # Deployment + 3 PVCs (photos/previews/medium) + Service
    ├── 50-mine-sim.yaml        # Deployment + PVC (game data) + Service
    └── 60-ingressroutes.yaml   # 3 routes, TLS via the letsencrypt resolver
```

`${DOMAIN}`, `${PLAY_DOMAIN}`, `${ACME_EMAIL}`, image tags and
`${MINESIM_WORKERS}` (auto = host CPU count) are substituted from `.env` by
`deploy.sh` before `kubectl apply`. The Postgres password is **not** in `.env`;
it is generated into the `app-secrets` Secret on first deploy.

## Persistence (k3s local-path, under `/var/lib/rancher/k3s/storage`)

| PVC                    | Holds                                   |
|------------------------|-----------------------------------------|
| `postgres-data`        | PostgreSQL database                     |
| `photo-book-photos`    | Original photos                         |
| `photo-book-previews`  | Generated preview thumbnails (cache)    |
| `photo-book-medium`    | Generated medium images (cache)         |
| `mine-sim-data`        | mine-sim admin password + SQLite DB     |

To import existing photos, copy them into the `photo-book-photos` PVC directory
on the host (its path is shown by `make status`).
