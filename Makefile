# infra-26 — convenience targets. Run on the VPS (uses the k3s kubeconfig).
export KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml
KUBECTL := $(shell command -v kubectl >/dev/null 2>&1 && echo kubectl || echo k3s kubectl)

.PHONY: help bootstrap deploy update restart status status-mon password \
        logs-photo logs-mine logs-getaround logs-sitegen logs-traefik logs-db logs-grafana logs-loki \
        logs-dtrack logs-dtrack-db db-backup db-backups db-restore nas-secret nas-sync

help:
	@echo "Targets:"
	@echo "  bootstrap     Install k3s on a fresh VPS, then deploy (sudo)."
	@echo "  deploy        Render manifests from .env and apply them."
	@echo "  update        Pull :latest images and rolling-restart the apps."
	@echo "  restart       Restart every workload."
	@echo "  status        Show pods, services, ingressroutes and volumes (web)."
	@echo "  status-mon    Show the monitoring stack (pods, svc, pvc)."
	@echo "  password      Print the generated Postgres / admin / Grafana passwords."
	@echo "  db-backup     Dump the photo-book database now (the nightly CronJob, on demand)."
	@echo "  db-backups    List the dumps kept (last 14)."
	@echo "  db-restore F=<file.dump>  Restore the photo-book database from one of them."
	@echo "  nas-secret    Store the home NAS rsync login (prompts; password typed hidden)."
	@echo "  nas-sync      Copy photos + dumps to the NAS now (the 4×/day CronJob, on demand)."
	@echo "  logs-photo|logs-mine|logs-getaround|logs-sitegen|logs-db|logs-dtrack|logs-dtrack-db|logs-traefik|logs-grafana|logs-loki  Tail logs."

bootstrap:
	sudo ./bootstrap.sh

deploy:
	./deploy.sh

update:
	$(KUBECTL) -n web rollout restart deploy/photo-book deploy/mine-sim deploy/getaround deploy/site-gen
	$(KUBECTL) -n web rollout status  deploy/photo-book
	$(KUBECTL) -n web rollout status  deploy/mine-sim
	$(KUBECTL) -n web rollout status  deploy/getaround
	$(KUBECTL) -n web rollout status  deploy/site-gen

restart:
	$(KUBECTL) -n web rollout restart deploy/photo-book deploy/mine-sim deploy/getaround deploy/site-gen deploy/postgres

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
	@printf 'getaround (admin)   : '; $(KUBECTL) -n web        get secret getaround-basic-auth-plain -o jsonpath='{.data.plaintext}'    | base64 -d; echo
	@printf 'site-gen (admin)    : '; $(KUBECTL) -n web        get secret site-gen-basic-auth-plain -o jsonpath='{.data.plaintext}'     | base64 -d; echo
	@printf 'Grafana (admin)     : '; $(KUBECTL) -n monitoring get secret grafana-admin           -o jsonpath='{.data.admin-password}'   | base64 -d; echo

logs-photo:
	$(KUBECTL) -n web logs -f deploy/photo-book
logs-mine:
	$(KUBECTL) -n web logs -f deploy/mine-sim
logs-getaround:
	$(KUBECTL) -n web logs -f deploy/getaround
logs-sitegen:
	$(KUBECTL) -n web logs -f deploy/site-gen
logs-dtrack:
	$(KUBECTL) -n web logs -f deploy/dtrack-apiserver
logs-dtrack-db:
	$(KUBECTL) -n web logs -f deploy/dtrack-postgres
logs-db:
	$(KUBECTL) -n web logs -f deploy/postgres
logs-traefik:
	$(KUBECTL) -n kube-system logs -f deploy/traefik
logs-grafana:
	$(KUBECTL) -n monitoring logs -f deploy/grafana
logs-loki:
	$(KUBECTL) -n monitoring logs -f statefulset/loki

# ── photo-book database backups (CronJob postgres-backup, 30-postgres.yaml) ──
db-backup:
	@job=postgres-backup-manual-$$(date +%s); \
	$(KUBECTL) -n web create job --from=cronjob/postgres-backup $$job && \
	$(KUBECTL) -n web wait --for=condition=complete job/$$job --timeout=300s && \
	$(KUBECTL) -n web logs job/$$job

# a throw-away pod mounting the backups volume
BACKUP_POD = $(KUBECTL) -n web run backup-shell-$$(date +%s) --rm -i --restart=Never --image=postgres:16-alpine \
	--overrides='{"spec":{"securityContext":{"runAsUser":70,"fsGroup":70},"containers":[{"name":"b","image":"postgres:16-alpine","stdin":true,"command":["sh","-c","'"$$CMD"'"],"env":[{"name":"PGHOST","value":"postgres"},{"name":"PGUSER","value":"photobook"},{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"app-secrets","key":"POSTGRES_PASSWORD"}}}],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"postgres-backups"}}]}}'

db-backups:
	@CMD='ls -lh /backups'; $(BACKUP_POD)

db-restore:
	@test -n "$(F)" || { echo "usage: make db-restore F=photobook-YYYY-MM-DD_HHMM.dump"; exit 1; }
	@read -p "Replace the photo-book database with $(F)? photo-book is stopped meanwhile. [y/N] " a && [ "$$a" = y ]
	$(KUBECTL) -n web scale deploy/photo-book --replicas=0
	@CMD='pg_restore --clean --if-exists --no-owner -d photobook /backups/$(F)'; $(BACKUP_POD)
	$(KUBECTL) -n web scale deploy/photo-book --replicas=1


# ── Off-site copy to the home NAS (CronJob nas-sync, 32-nas-sync.yaml) ───────
# The login lives only in the Secret nas-rsync: typed here, never in the repo
# or .env. The NAS's SSH host keys are scanned now (IPv6) and pinned.
nas-secret:
	@set -e; d=$$(mktemp -d); trap 'rm -rf "$$d"' EXIT; \
	printf 'NAS host: '; read -r h; printf 'SSH port: '; read -r p; printf 'User: '; read -r u; \
	printf 'rsync module/path [RSYNC/vps1]: '; read -r m; m=$${m:-RSYNC/vps1}; \
	printf 'Password: '; stty -echo 2>/dev/null || true; IFS= read -r pw; stty echo 2>/dev/null || true; echo; \
	printf '%s' "$$pw" > "$$d/pw"; \
	ssh-keyscan -6 -p "$$p" "$$h" 2>/dev/null > "$$d/known_hosts"; \
	test -s "$$d/known_hosts" || { echo "no SSH answer from [$$h]:$$p over IPv6"; exit 1; }; \
	echo "NAS host keys (compare with DSM or the infra notes):"; ssh-keygen -lf "$$d/known_hosts"; \
	$(KUBECTL) -n web create secret generic nas-rsync \
	  --from-literal=NAS_HOST="$$h" --from-literal=NAS_PORT="$$p" --from-literal=NAS_USER="$$u" \
	  --from-literal=NAS_DEST="$$m" --from-file=NAS_PASSWORD="$$d/pw" --from-file=known_hosts="$$d/known_hosts" \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -

nas-sync:
	@job=nas-sync-manual-$$(date +%s); \
	$(KUBECTL) -n web create job --from=cronjob/nas-sync $$job && \
	$(KUBECTL) -n web wait --for=condition=ready pod -l job-name=$$job --timeout=120s && \
	$(KUBECTL) -n web logs -f job/$$job
