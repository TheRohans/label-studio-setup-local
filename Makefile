SHELL := /bin/bash

# ---- Required (no sane default, must be passed explicitly) ----
ifndef DATA_ROOT
$(error DATA_ROOT is required, e.g. make DATA_ROOT=/mnt/bigdrive/label-studio all)
endif

# ---- Configurable ----
LS_PORT              ?= 6767
LS_ADMIN_EMAIL        ?= admin@example.com
# true = local files are things to label directly (images/audio/video/pdf/text)
# false = local files are pre-built Label Studio task JSON
SOURCE_USE_BLOB_URLS ?= true
# Optional regex to restrict the source storage sync to specific files (e.g.
# only images, or excluding sidecar files some other tool left in tasks/).
# Empty by default - every file under tasks/ becomes a task, unfiltered.
REGEX_FILTER ?=

# Where Label Studio's SQLite db + internal upload/media handling live.
# Defaults inside DATA_ROOT, but override this if DATA_ROOT is on a
# vfat/exFAT/NTFS drive: those filesystems have no per-file permission bits,
# so any chmod (which Label Studio's upload handling does on every saved
# file) fails with "Operation not permitted" no matter how the drive is
# mounted - a filesystem limitation, not a fixable permission setting.
# tasks/ and annotations/ (plain file drops) are fine on those filesystems;
# only this directory actually needs real Unix semantics. Point it at
# somewhere on the host's native filesystem instead, e.g.:
#   make DATA_ROOT=/mnt/bigdrive/label-studio LS_INTERNAL_DIR=/var/lib/label-studio-internal up
LS_INTERNAL_DIR ?= $(DATA_ROOT)/ls-internal

# Docker already publishes LS_PORT on all interfaces by default (see
# docker-compose.yml), so the container is reachable from your LAN regardless
# of this value - LS_HOST only controls what URL gets *printed*. Auto-detected
# from the primary NIC; override if that guesses wrong (multiple NICs, VPN,
# etc.) or you'd rather use a hostname: make LS_HOST=192.168.1.50 up
LS_HOST ?= $(shell hostname -I 2>/dev/null | awk '{print $$1}')
ifeq ($(strip $(LS_HOST)),)
LS_HOST := localhost
endif

ADMIN_PASSWORD_FILE := .label-studio-admin-password
ADMIN_TOKEN_FILE     := .label-studio-api-token

COMPOSE = DATA_ROOT=$(DATA_ROOT) LS_INTERNAL_DIR=$(LS_INTERNAL_DIR) LS_PORT=$(LS_PORT) LS_ADMIN_EMAIL=$(LS_ADMIN_EMAIL) \
          LS_ADMIN_PASSWORD=$$(cat $(ADMIN_PASSWORD_FILE)) LS_ADMIN_TOKEN=$$(cat $(ADMIN_TOKEN_FILE)) \
          docker compose

.PHONY: help all init-data up down logs admin-info configure-storage sync sync-to-cloud destroy

help:
	@echo "Label Studio, locally on Docker - SQLite db + local-disk storage"
	@echo ""
	@echo "Usage: make DATA_ROOT=/path/on/your/drive <target>"
	@echo ""
	@echo "  all               Full setup: create data dirs, start the container"
	@echo "  init-data         Create tasks/, annotations/ under DATA_ROOT and LS_INTERNAL_DIR"
	@echo "  up                Start Label Studio (docker compose up -d)"
	@echo "  down              Stop Label Studio (data on DATA_ROOT is untouched)"
	@echo "  logs              Tail container logs"
	@echo "  admin-info        Print the Label Studio admin login + API token"
	@echo "  configure-storage Wire up Source/Target local storage (needs LS_PROJECT_ID)"
	@echo "  sync              Trigger a re-sync after dropping new files in tasks/"
	@echo "  sync-to-cloud     Push tasks/+annotations/ to a gs:// or s3:// bucket (needs BUCKET_URL)"
	@echo "  destroy           Stop and remove the container (DATA_ROOT is left in place)"
	@echo ""
	@echo "See README.md for the first-run walkthrough and the cloud continuation path."

all: init-data up
	@echo ""
	@echo "Running at http://$(LS_HOST):$(LS_PORT). Log in (see 'make admin-info'), create a"
	@echo "project with your labeling config, then 'make LS_PROJECT_ID=<id> configure-storage'."

init-data:
	mkdir -p "$(DATA_ROOT)"/tasks "$(DATA_ROOT)"/annotations "$(LS_INTERNAL_DIR)"
	@echo "Data dirs ready:"
	@echo "  $(DATA_ROOT)/tasks/         <- drop raw files here to label"
	@echo "  $(DATA_ROOT)/annotations/   <- finished annotation JSON lands here"
	@echo "  $(LS_INTERNAL_DIR)   <- Label Studio's SQLite db + internal state, don't touch"

$(ADMIN_PASSWORD_FILE):
	@openssl rand -base64 24 > $(ADMIN_PASSWORD_FILE)
	@chmod 600 $(ADMIN_PASSWORD_FILE)

$(ADMIN_TOKEN_FILE):
	@openssl rand -hex 20 > $(ADMIN_TOKEN_FILE)
	@chmod 600 $(ADMIN_TOKEN_FILE)

up: init-data $(ADMIN_PASSWORD_FILE) $(ADMIN_TOKEN_FILE)
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory admin-info

down: $(ADMIN_PASSWORD_FILE) $(ADMIN_TOKEN_FILE)
	$(COMPOSE) down

logs: $(ADMIN_PASSWORD_FILE) $(ADMIN_TOKEN_FILE)
	$(COMPOSE) logs -f

admin-info: $(ADMIN_PASSWORD_FILE) $(ADMIN_TOKEN_FILE)
	@echo "Label Studio admin login:"
	@echo "  url:      http://$(LS_HOST):$(LS_PORT)"
	@echo "  email:    $(LS_ADMIN_EMAIL)"
	@echo "  password: $$(cat $(ADMIN_PASSWORD_FILE))"
	@echo "  api token: $$(cat $(ADMIN_TOKEN_FILE))"
	@echo ""
	@echo "NOTE: LABEL_STUDIO_USER_TOKEN is not honored as a token preset - the value above"
	@echo "won't work yet. Log in with the email/password above, click 'Create new token'"
	@echo "under Account & Settings, and overwrite $(ADMIN_TOKEN_FILE) with the real one"
	@echo "before running configure-storage/sync."

configure-storage: $(ADMIN_TOKEN_FILE)
	@if [ -z "$(LS_PROJECT_ID)" ]; then \
		echo "LS_PROJECT_ID is required." >&2; \
		echo "Log into Label Studio (http://$(LS_HOST):$(LS_PORT)), create your project" >&2; \
		echo "with a labeling config for your data, copy its numeric ID from the URL, then:" >&2; \
		echo "  make LS_PROJECT_ID=<id> configure-storage" >&2; \
		exit 1; \
	fi
	@TOKEN=$$(cat $(ADMIN_TOKEN_FILE)); \
	./scripts/configure-storage.sh "http://localhost:$(LS_PORT)" "$$TOKEN" "$(LS_PROJECT_ID)" "/label-studio/files/tasks" "/label-studio/files/annotations" "$(SOURCE_USE_BLOB_URLS)" "$(REGEX_FILTER)"

sync: $(ADMIN_TOKEN_FILE)
	@if [ -z "$(LS_PROJECT_ID)" ]; then \
		echo "LS_PROJECT_ID is required, e.g. make LS_PROJECT_ID=<id> sync" >&2; \
		exit 1; \
	fi
	@TOKEN=$$(cat $(ADMIN_TOKEN_FILE)); \
	./scripts/sync-storage.sh "http://localhost:$(LS_PORT)" "$$TOKEN" "$(LS_PROJECT_ID)"

sync-to-cloud:
	@if [ -z "$(BUCKET_URL)" ]; then \
		echo "BUCKET_URL is required, e.g. make BUCKET_URL=gs://my-bucket sync-to-cloud" >&2; \
		exit 1; \
	fi
	./scripts/sync-to-cloud.sh "$(DATA_ROOT)" "$(BUCKET_URL)"

destroy: $(ADMIN_PASSWORD_FILE) $(ADMIN_TOKEN_FILE)
	$(COMPOSE) down
	@echo "Container removed. Your data is untouched at $(DATA_ROOT)."
