SHELL := /bin/bash

GO ?= go
PY ?= python3

REGION ?= us-east-2
STATE_BUCKET ?=

GO_TEST_TIMEOUT ?= 30m

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make janitor      Janitor Python unit test (no AWS calls)"
	@echo "  make vpc          VPC module integration test (provisions real AWS)"
	@echo "  make lab1         Lab #1 end-to-end (happy-path + nacl-deny-egress, ~20m, ~\$$0.04)"
	@echo "  make lab2         Lab #2 end-to-end (happy-path + nacl-stateless-return, ~20m, ~\$$0.06)"
	@echo "  make integration  vpc + lab1 + lab2 (~50m sequential, faster in CI per-job)"
	@echo "  make all          janitor + vpc + lab1 + lab2"
	@echo "  make tidy         go mod tidy + python deps"
	@echo ""
	@echo "Required for the AWS targets:"
	@echo "  STATE_BUCKET=<bucket-name>   S3 bucket for per-test isolated state"
	@echo "  REGION=<region>              AWS region (default us-east-2)"
	@echo "  AWS credentials in env via aws-vault, SSO, or assume-role"

.PHONY: tidy
tidy:
	cd $(CURDIR) && $(GO) mod tidy
	$(PY) -m pip install --quiet -r janitor/requirements-dev.txt

.PHONY: janitor
janitor:
	cd janitor && $(PY) -m pytest -v

.PHONY: vpc
vpc: _require_state_bucket
	cd $(CURDIR) && \
		TERRATEST_STATE_BUCKET=$(STATE_BUCKET) \
		AWS_REGION=$(REGION) \
		$(GO) test ./vpc/... -v -timeout $(GO_TEST_TIMEOUT)

.PHONY: lab1
lab1: _require_state_bucket
	cd $(CURDIR) && \
		TERRATEST_STATE_BUCKET=$(STATE_BUCKET) \
		AWS_REGION=$(REGION) \
		$(GO) test ./lab1/... -v -timeout $(GO_TEST_TIMEOUT) -parallel 2

.PHONY: lab2
lab2: _require_state_bucket
	cd $(CURDIR) && \
		TERRATEST_STATE_BUCKET=$(STATE_BUCKET) \
		AWS_REGION=$(REGION) \
		$(GO) test ./lab2/... -v -timeout $(GO_TEST_TIMEOUT) -parallel 2

.PHONY: integration
integration: vpc lab1 lab2

.PHONY: all
all: janitor integration

.PHONY: _require_state_bucket
_require_state_bucket:
	@if [[ -z "$(STATE_BUCKET)" ]]; then echo "STATE_BUCKET is required"; exit 1; fi
