LIMA_INSTANCE ?= fabric-clab
PROJECT_DIR := $(CURDIR)
LIMA_RUN = limactl shell $(LIMA_INSTANCE) -- bash -lc 'cd "$(PROJECT_DIR)" && sudo

.PHONY: \
	up status smoke failover host-failover witness-failure test down clean \
	patroni-up patroni-status patroni-smoke patroni-process-failover \
	patroni-host-failover patroni-witness-failure patroni-test patroni-down patroni-clean \
	pcmk-up pcmk-status pcmk-smoke pcmk-failover pcmk-test pcmk-down pcmk-clean \
	test-all status-all clean-all deploy-lint

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

status-all: patroni-status pcmk-status

test-all: patroni-test pcmk-test

clean-all: patroni-clean pcmk-clean

deploy-lint:
	bash tests/deploy-templates.sh
