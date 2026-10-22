# Offline Research iOS — one entry point for every build step.
#
#   make bootstrap     # check tools, fetch llama.cpp, build the native libs
#   make project       # generate OfflineResearch.xcodeproj (XcodeGen)
#   make model         # download + verify the default GGUF (no model in git)
#   make index         # rebuild corpus.sqlite from Corpus/raw/wiki.jsonl
#   make corpus        # fetch the corpus (network, build-time only)
#   make eval          # retrieval metrics against the bundled index
#   make verify        # everything checkable without a Mac/Xcode
#   make open          # open the project in Xcode
#   make dist          # tarball of the sources (no model, no vendor)

SHELL := /bin/bash
.DEFAULT_GOAL := help

MODEL ?= qwen2.5-1.5b-instruct-q4_k_m
XCODEGEN := $(shell command -v xcodegen || true)
PYTHON := python3

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: doctor
doctor: ## Check the local toolchain
	@bash Scripts/doctor.sh

.PHONY: llama
llama: ## Build vendor/llama (llama.cpp v0.7.0, Metal + Accelerate) for device + simulator
	@bash Scripts/build_llama.sh

.PHONY: llama-cpu
llama-cpu: ## Build vendor/llama with the CPU backend only (no Metal)
	@bash Scripts/build_llama.sh --cpu-only

.PHONY: bootstrap
bootstrap: doctor llama ## Doctor + native libs
	@echo "bootstrap complete. Next: make project && make open"

.PHONY: project
project: ## Generate the Xcode project (requires XcodeGen + native libs)
	@test -n "$(XCODEGEN)" || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	@test -d vendor/llama/lib || { echo "native libs missing: run 'make llama' (or 'make project-nollama')"; exit 1; }
	xcodegen generate
	@echo "Open with: make open"

.PHONY: project-nollama
project-nollama: ## Generate the project in retrieval-only mode (no native libs needed)
	@test -n "$(XCODEGEN)" || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	xcodegen generate
	@echo "Retrieval-only build: select the OfflineResearch-NoLlama scheme."

.PHONY: open
open: ## Open the generated project
	open OfflineResearch.xcodeproj

.PHONY: corpus
corpus: ## Fetch the corpus from Wikipedia (network, build time only)
	$(PYTHON) Scripts/fetch_corpus.py --limit 200 --per-request-delay 1.0

.PHONY: index
index: ## Rebuild App/Resources/corpus.sqlite
	$(PYTHON) Scripts/build_index.py

.PHONY: model
model: ## Download + checksum the default GGUF into Models/
	@bash Scripts/fetch_model.sh $(MODEL)

.PHONY: model-list
model-list: ## Show catalog profiles
	@bash Scripts/fetch_model.sh --list

.PHONY: eval
eval: ## Retrieval metrics (hit@1, hit@3, MRR)
	$(PYTHON) Scripts/eval_retrieval.py --verbose --json docs/retrieval_eval.json

.PHONY: verify
verify: ## Offline check, JSON/YAML/plist/sqlite validation, script smoke tests
	@bash Scripts/verify_repo.sh

.PHONY: verify-core
verify-core: ## swiftc -parse/-typecheck + retrieval smoke test (needs a Swift toolchain)
	@bash Scripts/dev/verify_core.sh

.PHONY: dist
dist: ## Source tarball (excludes model weights and vendor/)
	@mkdir -p dist
	@tar --exclude-vcs --exclude='./vendor' --exclude='./Models' --exclude='./dist' \
	     --exclude='./OfflineResearch.xcodeproj' \
	     -czf dist/offline-research-ios-src.tar.gz .
	@echo "dist/offline-research-ios-src.tar.gz"

.PHONY: clean
clean: ## Remove generated artefacts (keeps corpus + vendor)
	rm -rf OfflineResearch.xcodeproj dist .build
