#!/usr/bin/env bash
# deploy.sh — render the manifests from .env and apply them to the k3s cluster.
# Idempotent: safe to re-run for updates. Assumes k3s is already installed
# (run ./bootstrap.sh first on a fresh VPS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[infra-26]${RESET} $*"; }
ok()    { echo -e "${GREEN}[ok]${RESET}       $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}     $*"; }
die()   { echo -e "${RED}[err]${RESET}      $*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
[[ -f .env ]] || die "No .env found. Copy .env.example to .env and edit it."
set -a; . ./.env; set +a

: "${DOMAIN:?DOMAIN missing in .env}"
: "${PLAY_DOMAIN:?PLAY_DOMAIN missing in .env}"
: "${APP_DOMAIN:?APP_DOMAIN missing in .env}"
: "${ADMIN_DOMAIN:?ADMIN_DOMAIN missing in .env}"
: "${DTRACK_DOMAIN:?DTRACK_DOMAIN missing in .env}"
: "${ACME_EMAIL:?ACME_EMAIL missing in .env}"
: "${PHOTO_IMAGE:?PHOTO_IMAGE missing in .env}"
: "${MINESIM_IMAGE:?MINESIM_IMAGE missing in .env}"
: "${GETAROUND_IMAGE:?GETAROUND_IMAGE missing in .env}"
: "${SITEGEN_IMAGE:=jarod68/site-gen:latest}"
export DOMAIN PLAY_DOMAIN APP_DOMAIN ADMIN_DOMAIN DTRACK_DOMAIN ACME_EMAIL PHOTO_IMAGE MINESIM_IMAGE GETAROUND_IMAGE SITEGEN_IMAGE

# ── kubectl (prefer a real kubectl, fall back to `k3s kubectl`) ───────────────
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
if command -v kubectl >/dev/null 2>&1 && [[ -r "$KUBECONFIG" ]]; then
  KUBECTL="kubectl"
elif command -v k3s >/dev/null 2>&1; then
  KUBECTL="k3s kubectl"
else
  die "Neither kubectl nor k3s found. Run ./bootstrap.sh first."
fi
command -v envsubst >/dev/null 2>&1 || die "envsubst is required (package: gettext-base)."

# ── Namespace + secret ────────────────────────────────────────────────────────
info "Applying namespace …"
$KUBECTL apply -f manifests/00-namespace.yaml

gen_pw() { openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32; }
# Read one key out of the app-secrets secret (empty if the secret/key is absent).
read_secret_key() { $KUBECTL -n web get secret app-secrets -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true; }

ensure_secret() {
  # Reuse existing passwords so a redeploy never rotates a live DB credential;
  # generate any that are still missing.
  local pw dtpw
  pw="$(read_secret_key POSTGRES_PASSWORD)"
  dtpw="$(read_secret_key DTRACK_DB_PASSWORD)"
  [[ -n "$pw"   ]] && info "Reusing existing Postgres password."               || { pw="$(gen_pw)";   info "Generated a new Postgres password."; }
  [[ -n "$dtpw" ]] && info "Reusing existing Dependency-Track DB password."     || { dtpw="$(gen_pw)"; info "Generated a new Dependency-Track DB password."; }
  local args=(--from-literal=POSTGRES_PASSWORD="$pw" --from-literal=DTRACK_DB_PASSWORD="$dtpw")
  [[ -n "${VAPID_PUBLIC_KEY:-}"  ]] && args+=(--from-literal=VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY")
  [[ -n "${VAPID_PRIVATE_KEY:-}" ]] && args+=(--from-literal=VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY")
  [[ -n "${VAPID_SUBJECT:-}"     ]] && args+=(--from-literal=VAPID_SUBJECT="$VAPID_SUBJECT")
  $KUBECTL -n web create secret generic app-secrets "${args[@]}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
}
ensure_secret
ok "Secret app-secrets ready."

# ── Docker Hub pull secret (getaround image is PRIVATE) ───────────────────────
# Created/refreshed from DOCKERHUB_USER + DOCKERHUB_TOKEN in .env; an existing
# secret is reused when the vars are absent (so a redeploy doesn't need them).
ensure_regcred() {
  if [[ -n "${DOCKERHUB_USER:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
    $KUBECTL -n web create secret docker-registry regcred-dockerhub \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="$DOCKERHUB_USER" \
      --docker-password="$DOCKERHUB_TOKEN" \
      --dry-run=client -o yaml | $KUBECTL apply -f -
    ok "Secret regcred-dockerhub ready (from .env)."
  elif $KUBECTL -n web get secret regcred-dockerhub >/dev/null 2>&1; then
    info "Reusing existing regcred-dockerhub."
  else
    die "GETAROUND_IMAGE is private: set DOCKERHUB_USER and DOCKERHUB_TOKEN in .env (a read-only access token)."
  fi
}
ensure_regcred

# ── Admin basic-auth (Traefik, guards admin.holtz.fr) ─────────────────────────
# Strong random password, generated once and reused on redeploy. Stored in TWO
# secrets, because Traefik's basicAuth secret must contain EXACTLY ONE key:
#   admin-basic-auth       — key `users`: apr1 hash in htpasswd form (Traefik)
#   admin-basic-auth-plain — key `plaintext`: clear password (`make password`)
ensure_basic_auth() {
  if $KUBECTL -n web get secret admin-basic-auth-plain >/dev/null 2>&1; then
    info "Reusing existing admin basic-auth password."
    return
  fi
  local pw hash
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  hash="$(openssl passwd -apr1 "$pw")"
  $KUBECTL -n web create secret generic admin-basic-auth \
    --from-literal=users="admin:${hash}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL -n web create secret generic admin-basic-auth-plain \
    --from-literal=plaintext="$pw" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  info "Generated a new admin basic-auth password (see: make password)."
}
ensure_basic_auth
ok "Secrets admin-basic-auth{,-plain} ready."

# ── getaround basic-auth (guards app.holtz.fr/getaround) ──────────────────────
# Same two-secret scheme as the admin auth (Traefik needs exactly one key).
ensure_getaround_auth() {
  if $KUBECTL -n web get secret getaround-basic-auth-plain >/dev/null 2>&1; then
    info "Reusing existing getaround basic-auth password."
    return
  fi
  local pw hash
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  hash="$(openssl passwd -apr1 "$pw")"
  $KUBECTL -n web create secret generic getaround-basic-auth \
    --from-literal=users="admin:${hash}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL -n web create secret generic getaround-basic-auth-plain \
    --from-literal=plaintext="$pw" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  info "Generated a new getaround basic-auth password (see: make password)."
}
ensure_getaround_auth
ok "Secrets getaround-basic-auth{,-plain} ready."

# ── site-gen basic-auth (guards app.holtz.fr/site-gen) + Google API key ──────
ensure_sitegen_auth() {
  if $KUBECTL -n web get secret site-gen-basic-auth-plain >/dev/null 2>&1; then
    info "Reusing existing site-gen basic-auth password."
    return
  fi
  local pw hash
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  hash="$(openssl passwd -apr1 "$pw")"
  $KUBECTL -n web create secret generic site-gen-basic-auth \
    --from-literal=users="admin:${hash}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL -n web create secret generic site-gen-basic-auth-plain \
    --from-literal=plaintext="$pw" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  info "Generated a new site-gen basic-auth password (see: make password)."
}
ensure_sitegen_auth
ok "Secrets site-gen-basic-auth{,-plain} ready."

# GOOGLE_MAPS_API_KEY (optional) → site-gen-secrets. Left blank, an existing
# secret is kept; with none at all site-gen only offers the OpenStreetMap source.
if [[ -n "${GOOGLE_MAPS_API_KEY:-}" ]]; then
  $KUBECTL -n web create secret generic site-gen-secrets \
    --from-literal=GOOGLE_MAPS_API_KEY="$GOOGLE_MAPS_API_KEY" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  ok "Secret site-gen-secrets ready (Google Places key)."
else
  warn "GOOGLE_MAPS_API_KEY not set: site-gen keeps its existing key, or runs OpenStreetMap-only."
fi

# ── Monitoring namespace + Grafana admin password ─────────────────────────────
# The kube-prometheus-stack HelmChart also creates this namespace, but we need it
# now so the Grafana admin Secret exists before Grafana's pod starts.
info "Ensuring monitoring namespace …"
$KUBECTL create namespace monitoring --dry-run=client -o yaml | $KUBECTL apply -f -

ensure_grafana_admin() {
  if $KUBECTL -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    info "Reusing existing Grafana admin password."
    return
  fi
  local pw
  pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  $KUBECTL -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$pw" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  info "Generated a new Grafana admin password (see: make password)."
}
ensure_grafana_admin
ok "Secret grafana-admin ready."

# ── Traefik: Let's Encrypt resolver + HTTP→HTTPS redirect ────────────────────
info "Configuring Traefik (Let's Encrypt resolver) …"
envsubst '$ACME_EMAIL' < manifests/10-traefik-acme.yaml | $KUBECTL apply -f -

# Wait for the bundled Traefik to have installed its CRDs before we use them.
# (On a fresh cluster the CRDs may not exist yet, so wait for them to appear
# first — `kubectl wait` errors immediately on a missing resource.)
info "Waiting for Traefik CRDs …"
for crd in ingressroutes.traefik.io middlewares.traefik.io; do
  # Wait until the CRD exists AND its .status.conditions is populated. A freshly
  # created CRD has a nil status for a moment, and `kubectl wait` errors out
  # ("<nil> is of the type <nil>") instead of waiting when that field is absent.
  for _ in $(seq 1 60); do
    $KUBECTL get crd "$crd" -o jsonpath='{.status.conditions}' 2>/dev/null | grep -q . && break
    sleep 3
  done
  $KUBECTL wait --for=condition=established "crd/$crd" --timeout=120s \
    || die "Traefik CRD $crd not ready — is the bundled Traefik enabled?"
done

# ── Render + apply the rest (substituting only our known vars) ────────────────
VARS='$DOMAIN $PLAY_DOMAIN $APP_DOMAIN $ADMIN_DOMAIN $DTRACK_DOMAIN $ACME_EMAIL $PHOTO_IMAGE $MINESIM_IMAGE $GETAROUND_IMAGE $SITEGEN_IMAGE'
RENDER="$(mktemp -d)"; trap 'rm -rf "$RENDER"' EXIT
for f in manifests/15-middlewares.yaml \
         manifests/30-postgres.yaml \
         manifests/40-photo-book.yaml \
         manifests/50-mine-sim.yaml \
         manifests/55-getaround.yaml \
         manifests/56-site-gen.yaml \
         manifests/60-ingressroutes.yaml \
         manifests/70-portainer.yaml \
         manifests/80-monitoring.yaml \
         manifests/81-grafana-dashboards.yaml \
         manifests/85-admin-ingress.yaml \
         manifests/90-dependency-track.yaml; do
  envsubst "$VARS" < "$f" > "$RENDER/$(basename "$f")"
done
info "Applying application + monitoring manifests …"
$KUBECTL apply -f "$RENDER"

# ── Decommission resources removed from the manifests ─────────────────────────
# `kubectl apply` never prunes, so anything we drop from manifests/ keeps running
# until deleted explicitly. Keep this idempotent (‑‑ignore-not-found).
info "Pruning decommissioned resources …"
$KUBECTL -n web delete deploy/adminer svc/adminer ingressroute/adminer --ignore-not-found

ok "Deployed. Pods are starting:"
$KUBECTL -n web get pods
echo
echo -e "  photo-book : ${GREEN}https://${DOMAIN}${RESET}"
echo -e "  mine-sim   : ${GREEN}https://${PLAY_DOMAIN}${RESET}"
echo -e "  getaround  : ${GREEN}https://${APP_DOMAIN}/getaround${RESET}"
echo -e "  site-gen   : ${GREEN}https://${APP_DOMAIN}/site-gen${RESET}"
echo -e "  portainer  : ${GREEN}https://${ADMIN_DOMAIN}/portainer${RESET}"
echo -e "  grafana    : ${GREEN}https://${ADMIN_DOMAIN}/grafana${RESET}"
echo -e "  dep-track  : ${GREEN}https://${DTRACK_DOMAIN}${RESET}  (UI behind admin basic-auth; first login admin/admin)"
echo
warn "DNS A+AAAA for ${DOMAIN}, ${PLAY_DOMAIN}, ${APP_DOMAIN}, ${ADMIN_DOMAIN} and ${DTRACK_DOMAIN} must point to this VPS. TLS is issued on first HTTPS hit (~30 s)."
warn "Dependency-Track's apiserver is JVM-based (4 GB heap min — it refuses to start below) and takes a few minutes on first boot: kubectl -n web rollout status deploy/dtrack-apiserver"
warn "Monitoring charts (kube-prometheus-stack, loki) install asynchronously — give them a few minutes: kubectl -n monitoring get pods"
