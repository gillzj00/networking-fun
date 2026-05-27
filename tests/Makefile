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
	@echo "  make all          janitor + vpc"
	@echo "  make tidy         go mod tidy + python deps"
	@echo ""
	@echo "Required for vpc:"
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
vpc:
	@if [[ -z "$(STATE_BUCKET)" ]]; then echo "STATE_BUCKET is required"; exit 1; fi
	cd $(CURDIR) && \
		TERRATEST_STATE_BUCKET=$(STATE_BUCKET) \
		AWS_REGION=$(REGION) \
		$(GO) test ./vpc/... -v -timeout $(GO_TEST_TIMEOUT)

.PHONY: all
all: janitor vpc
