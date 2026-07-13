# infra-26 — convenience targets. Run on the VPS (uses the k3s kubeconfig).
export KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml
KUBECTL := $(shell command -v kubectl >/dev/null 2>&1 && echo kubectl || echo k3s kubectl)

.PHONY: help bootstrap deploy update restart status status-mon password \
        logs-photo logs-mine logs-traefik logs-db logs-grafana logs-loki

help:
	@echo "Targets:"
	@echo "  bootstrap     Install k3s on a fresh VPS, then deploy (sudo)."
	@echo "  deploy        Render manifests from .env and apply them."
	@echo "  update        Pull :latest images and rolling-restart the apps."
	@echo "  restart       Restart every workload."
	@echo "  status        Show pods, services, ingressroutes and volumes (web)."
	@echo "  status-mon    Show the monitoring stack (pods, svc, pvc)."
	@echo "  password      Print the generated Postgres / admin / Grafana passwords."
	@echo "  logs-photo|logs-mine|logs-db|logs-traefik|logs-grafana|logs-loki  Tail logs."

bootstrap:
	sudo ./bootstrap.sh

deploy:
	./deploy.sh

update:
	$(KUBECTL) -n web rollout restart deploy/photo-book deploy/mine-sim
	$(KUBECTL) -n web rollout status  deploy/photo-book
	$(KUBECTL) -n web rollout status  deploy/mine-sim

restart:
	$(KUBECTL) -n web rollout restart deploy/photo-book deploy/mine-sim deploy/adminer deploy/postgres

status:
	@$(KUBECTL) -n web get pods,svc,ingressroute
	@echo
	@$(KUBECTL) -n web get pvc

status-mon:
	@$(KUBECTL) -n monitoring get pods,svc
	@echo
	@$(KUBECTL) -n monitoring get pvc

password:
	@printf 'Postgres            : '; $(KUBECTL) -n web        get secret app-secrets             -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
	@printf 'admin basic-auth    : '; $(KUBECTL) -n web        get secret admin-basic-auth-plain  -o jsonpath='{.data.plaintext}'        | base64 -d; echo
	@printf 'Grafana (admin)     : '; $(KUBECTL) -n monitoring get secret grafana-admin           -o jsonpath='{.data.admin-password}'   | base64 -d; echo

logs-photo:
	$(KUBECTL) -n web logs -f deploy/photo-book
logs-mine:
	$(KUBECTL) -n web logs -f deploy/mine-sim
logs-db:
	$(KUBECTL) -n web logs -f deploy/postgres
logs-traefik:
	$(KUBECTL) -n kube-system logs -f deploy/traefik
logs-grafana:
	$(KUBECTL) -n monitoring logs -f deploy/grafana
logs-loki:
	$(KUBECTL) -n monitoring logs -f statefulset/loki
