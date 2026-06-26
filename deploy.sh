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
: "${ACME_EMAIL:?ACME_EMAIL missing in .env}"
: "${PHOTO_IMAGE:?PHOTO_IMAGE missing in .env}"
: "${MINESIM_IMAGE:?MINESIM_IMAGE missing in .env}"
# One mine-sim worker per CPU core unless pinned in .env (1 ⇒ single process).
: "${MINESIM_WORKERS:=$(nproc 2>/dev/null || echo 1)}"
export DOMAIN PLAY_DOMAIN ACME_EMAIL PHOTO_IMAGE MINESIM_IMAGE MINESIM_WORKERS

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

ensure_secret() {
  local pw
  if $KUBECTL -n web get secret app-secrets >/dev/null 2>&1; then
    pw="$($KUBECTL -n web get secret app-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
    info "Reusing existing Postgres password from app-secrets."
  else
    pw="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)"
    info "Generated a new Postgres password."
  fi
  local args=(--from-literal=POSTGRES_PASSWORD="$pw")
  [[ -n "${VAPID_PUBLIC_KEY:-}"  ]] && args+=(--from-literal=VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY")
  [[ -n "${VAPID_PRIVATE_KEY:-}" ]] && args+=(--from-literal=VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY")
  [[ -n "${VAPID_SUBJECT:-}"     ]] && args+=(--from-literal=VAPID_SUBJECT="$VAPID_SUBJECT")
  $KUBECTL -n web create secret generic app-secrets "${args[@]}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
}
ensure_secret
ok "Secret app-secrets ready."

# ── Traefik: Let's Encrypt resolver + HTTP→HTTPS redirect ────────────────────
info "Configuring Traefik (Let's Encrypt resolver) …"
envsubst '$ACME_EMAIL' < manifests/10-traefik-acme.yaml | $KUBECTL apply -f -

# Wait for the bundled Traefik to have installed its CRDs before we use them.
# (On a fresh cluster the CRDs may not exist yet, so wait for them to appear
# first — `kubectl wait` errors immediately on a missing resource.)
info "Waiting for Traefik CRDs …"
for crd in ingressroutes.traefik.io middlewares.traefik.io; do
  for _ in $(seq 1 60); do
    $KUBECTL get crd "$crd" >/dev/null 2>&1 && break
    sleep 3
  done
  $KUBECTL wait --for=condition=established "crd/$crd" --timeout=120s \
    || die "Traefik CRD $crd not ready — is the bundled Traefik enabled?"
done

# ── Render + apply the rest (substituting only our known vars) ────────────────
VARS='$DOMAIN $PLAY_DOMAIN $ACME_EMAIL $PHOTO_IMAGE $MINESIM_IMAGE $MINESIM_WORKERS'
RENDER="$(mktemp -d)"; trap 'rm -rf "$RENDER"' EXIT
for f in manifests/15-middlewares.yaml \
         manifests/30-postgres.yaml \
         manifests/35-adminer.yaml \
         manifests/40-photo-book.yaml \
         manifests/50-mine-sim.yaml \
         manifests/60-ingressroutes.yaml; do
  envsubst "$VARS" < "$f" > "$RENDER/$(basename "$f")"
done
info "Applying application manifests …"
$KUBECTL apply -f "$RENDER"

ok "Deployed. Pods are starting:"
$KUBECTL -n web get pods
echo
echo -e "  photo-book : ${GREEN}https://${DOMAIN}${RESET}"
echo -e "  adminer    : ${GREEN}https://${DOMAIN}/db${RESET}"
echo -e "  mine-sim   : ${GREEN}https://${PLAY_DOMAIN}${RESET}"
echo
warn "DNS for ${DOMAIN} and ${PLAY_DOMAIN} must point to this VPS. TLS is issued on first HTTPS hit (~30 s)."
