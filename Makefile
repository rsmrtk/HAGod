.DEFAULT_GOAL := help
.PHONY: help up down reset seed seed-pg seed-redis overview shell status watch writer-start writer-stop report psql rcli obs-up obs-down drill-list heal gameday gameday-reveal
SHELL := /bin/bash

help:           ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

up:             ## start the whole lab (first run builds the Patroni image)
	docker compose up -d --build
	@echo "waiting for the cluster..."; ./scripts/wait-ready.sh

down:           ## stop the lab, keep the data
	docker compose --profile probe down

reset:          ## wipe EVERYTHING (data volumes too) and start clean
	docker compose --profile probe down -v
	$(MAKE) up

seed:           ## load training tables into Postgres and keys into Redis
	./scripts/seed.sh all

seed-pg:        ## recreate ONLY the bank database (after DROP experiments)
	./scripts/seed.sh pg

seed-redis:     ## reload ONLY the Redis training keys (after eviction/flush experiments)
	./scripts/seed.sh redis

overview:       ## what is in the databases: tables, sizes, Redis keys by type
	./scripts/overview.sh

shell:          ## a shell with psql, patronictl and redis-cli already pointed at the lab
	./scripts/shell.sh

status:         ## one-shot status of every component
	./scripts/status.sh

watch:          ## live dashboard (run it in a second terminal during drills)
	./scripts/watch.sh

writer-start:   ## start the probe that writes to both databases (measures RTO/RPO)
	docker compose --profile probe up -d --build writer

writer-stop:    ## stop the probe
	docker compose --profile probe stop writer

report:         ## RTO/RPO report from the probe's log
	./scripts/report.sh

psql:           ## psql on the primary through HAProxy
	./scripts/psql.sh

rcli:           ## redis-cli on the current Redis master
	./scripts/rcli.sh

obs-up:         ## optional: Prometheus + exporters + Grafana
	docker compose -f compose.yml -f obs/compose.obs.yml up -d

obs-down:
	docker compose -f compose.yml -f obs/compose.obs.yml stop prometheus grafana pg-exporter redis-exporter

drill-list:     ## list the drills
	@ls -1 drills | sed 's/^/  /'

drill-%:        ## run a drill's break script, e.g. make drill-01
	@d=$$(ls -d drills/$*-* | head -1); echo "== $$d"; cat $$d/README.md | sed -n '1,12p'; echo; read -p "Press Enter to BREAK it (Ctrl-C to stop)..." _; ./$$d/break.sh

verify-%:       ## check the result of a drill, e.g. make verify-01
	@d=$$(ls -d drills/$*-* | head -1); ./$$d/verify.sh

heal:           ## put everything back to normal after any drill
	./scripts/heal.sh

gameday:        ## a random failure you are NOT told about: diagnose it yourself
	./scripts/gameday.sh start

gameday-reveal: ## what the game day failure was
	./scripts/gameday.sh reveal
