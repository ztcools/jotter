SHELL := /bin/bash
.DEFAULT_GOAL := help

RUST_TARGET ?= x86_64-pc-windows-msvc
IMAGE       ?= jotter-winbuild
OUT_DIR     ?= dist-win

.PHONY: help install icons dev check fmt lint build windows clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## Install frontend dependencies
	pnpm install --frozen-lockfile

icons: ## Regenerate every icon asset from scripts/gen-icons.mjs
	pnpm icons

dev: ## Run the widget with hot reload (needs a local WebView + Rust toolchain)
	pnpm tauri dev

check: ## Type-check the frontend
	pnpm check

fmt: ## Format the Rust sources
	cd src-tauri && cargo fmt

lint: ## Rust formatting check + clippy (denies warnings)
	cd src-tauri && cargo fmt --check
	cd src-tauri && cargo clippy --locked --target $(RUST_TARGET) --all-targets -- -D warnings

build: ## Build the frontend bundle only
	pnpm build

windows: ## Cross-compile the portable Windows .exe inside Docker
	docker build \
		--file docker/Dockerfile.windows \
		--target artifact \
		--output type=local,dest=$(OUT_DIR) \
		--tag $(IMAGE) \
		.
	@ls -lh $(OUT_DIR)/Jotter.exe

clean: ## Remove build output
	rm -rf dist $(OUT_DIR) src-tauri/target src-tauri/gen
