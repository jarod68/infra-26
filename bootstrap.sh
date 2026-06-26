#!/usr/bin/env bash
# bootstrap.sh — fresh-VPS bootstrap: install single-node k3s, then deploy.
# Usage: sudo ./bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info() { echo -e "${CYAN}[infra-26]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ok]${RESET}       $*"; }
die()  { echo -e "${RED}[err]${RESET}      $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo ./bootstrap.sh"
[[ -f .env ]] || die "No .env found. Copy .env.example to .env and edit it first."

# ── envsubst (gettext) — needed by deploy.sh ──────────────────────────────────
if ! command -v envsubst >/dev/null 2>&1; then
  info "Installing gettext (envsubst) …"
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y gettext-base
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y gettext
  elif command -v yum     >/dev/null 2>&1; then yum install -y gettext
  else die "Install 'envsubst' (gettext) manually and re-run."; fi
fi

# ── k3s (single node, bundled Traefik + local-path + servicelb) ──────────────
if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s 2>/dev/null; then
  ok "k3s already installed and running."
else
  info "Installing k3s (single-node) …"
  # Defaults give us Traefik (ingress), local-path (storage) and servicelb
  # (binds :80/:443 on the host) — exactly what we need for one node.
  curl -sfL https://get.k3s.io | sh -
  ok "k3s installed."
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

info "Waiting for the node to be Ready …"
for _ in $(seq 1 60); do
  if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then break; fi
  sleep 2
done
k3s kubectl get nodes | grep -q ' Ready' || die "k3s node did not become Ready."
ok "Node Ready."

info "Deploying the stack …"
./deploy.sh

echo
ok "Bootstrap complete."
