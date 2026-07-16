LIMA_INSTANCE ?= fabric-clab
PROJECT_DIR := $(CURDIR)
LIMA_RUN = limactl shell $(LIMA_INSTANCE) -- bash -lc 'cd "$(PROJECT_DIR)" && sudo
DEMO_COMPOSE = docker compose -f demo/compose.yml

.PHONY: \
	up status smoke failover host-failover witness-failure test down clean \
	patroni-up patroni-status patroni-smoke patroni-process-failover \
	patroni-host-failover patroni-witness-failure patroni-test patroni-down patroni-clean \
	pcmk-up pcmk-status pcmk-smoke pcmk-failover pcmk-test pcmk-down pcmk-clean \
	manual-up manual-status manual-smoke manual-switch manual-promote manual-rejoin manual-failover manual-test manual-down manual-clean \
	test-all status-all clean-all deploy-lint \
	demo-up demo-status demo-failover demo-rejoin demo-down demo-clean

# Default aliases use the Patroni + external etcd witness design.
up: patroni-up
status: patroni-status
smoke: patroni-smoke
failover: patroni-process-failover
host-failover: patroni-host-failover
witness-failure: patroni-witness-failure
test: patroni-test
down: patroni-down
clean: patroni-clean

patroni-up:
	$(LIMA_RUN) bash scripts/lab-up.sh'

patroni-status:
	$(LIMA_RUN) bash scripts/status.sh'

patroni-smoke:
	$(LIMA_RUN) bash tests/smoke.sh'

patroni-process-failover:
	$(LIMA_RUN) bash tests/failover-process.sh'

patroni-host-failover:
	$(LIMA_RUN) bash tests/host-failover.sh'

patroni-witness-failure:
	$(LIMA_RUN) bash tests/witness-failure.sh'

patroni-test: patroni-up patroni-smoke patroni-process-failover patroni-witness-failure patroni-host-failover

patroni-down:
	$(LIMA_RUN) bash scripts/lab-down.sh'

patroni-clean:
	$(LIMA_RUN) bash scripts/lab-clean.sh'

pcmk-up:
	$(LIMA_RUN) bash scripts/pcmk-up.sh'

pcmk-status:
	$(LIMA_RUN) bash scripts/pcmk-status.sh'

pcmk-smoke:
	$(LIMA_RUN) bash tests/pcmk-smoke.sh'

pcmk-failover:
	$(LIMA_RUN) bash tests/pcmk-failover.sh'

pcmk-test: pcmk-up pcmk-smoke pcmk-failover

pcmk-down:
	$(LIMA_RUN) bash scripts/pcmk-down.sh'

pcmk-clean:
	$(LIMA_RUN) bash scripts/pcmk-clean.sh'

manual-up:
	$(LIMA_RUN) bash scripts/manual-up.sh'

manual-status:
	$(LIMA_RUN) bash scripts/manual-status.sh'

manual-smoke:
	$(LIMA_RUN) bash tests/manual-smoke.sh'

manual-switch:
	@test -n "$(FROM)" && test -n "$(TO)" || (echo 'usage: make manual-switch FROM=db1 TO=db2' >&2; exit 1)
	$(LIMA_RUN) bash scripts/manual-switch.sh "$(FROM)" "$(TO)"'

manual-promote:
	@test -n "$(NODE)" || (echo 'usage: make manual-promote NODE=db2' >&2; exit 1)
	$(LIMA_RUN) bash scripts/manual-promote.sh "$(NODE)"'

manual-rejoin:
	@test -n "$(NODE)" || (echo 'usage: make manual-rejoin NODE=db1' >&2; exit 1)
	$(LIMA_RUN) bash scripts/manual-rejoin.sh "$(NODE)"'

manual-failover:
	$(LIMA_RUN) bash tests/manual-failover.sh'

manual-test: manual-up manual-smoke manual-failover

manual-down:
	$(LIMA_RUN) bash scripts/manual-down.sh'

manual-clean:
	$(LIMA_RUN) bash scripts/manual-clean.sh'

status-all: patroni-status pcmk-status manual-status

test-all: patroni-test pcmk-test manual-test

clean-all: patroni-clean pcmk-clean manual-clean

deploy-lint:
	bash tests/deploy-templates.sh

demo-up:
	$(DEMO_COMPOSE) up -d --build

demo-status:
	$(DEMO_COMPOSE) ps
	@for port in 18108 18109; do \
		curl -fsS "http://127.0.0.1:$$port/patroni" || true; \
		printf '\n'; \
	done

demo-failover:
	bash scripts/demo-failover.sh

demo-rejoin:
	$(DEMO_COMPOSE) up -d pg1 pg2

demo-down:
	$(DEMO_COMPOSE) down

demo-clean:
	$(DEMO_COMPOSE) down -v --remove-orphans
