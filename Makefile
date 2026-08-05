SHELL := /bin/bash
.DEFAULT_GOAL := help

RUST_TARGET ?= x86_64-pc-windows-msvc
IMAGE       ?= jotter-winbuild
OUT_DIR     ?= dist-win

.PHONY: help install icons dev check fmt fmt-docker lint lint-docker build windows clean

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

# Runs as the invoking user so the rewritten sources do not come back owned by
# root; HOME is redirected because that user has none inside the container.
fmt-docker: ## Format the Rust sources inside the container, for machines with no Rust
	docker build --file docker/Dockerfile.windows --target base --tag $(IMAGE)-base .
	docker run --rm --user $$(id -u):$$(id -g) -e HOME=/tmp \
		--volume "$(CURDIR):/app" --workdir /app/src-tauri $(IMAGE)-base cargo fmt

lint: ## Rust formatting check + clippy (denies warnings; needs a host toolchain)
	cd src-tauri && cargo fmt --check
	cd src-tauri && cargo clippy --locked --features custom-protocol \
		--target $(RUST_TARGET) --all-targets -- -D warnings

lint-docker: ## Same checks inside the build container, for machines with no Rust
	docker build --file docker/Dockerfile.windows --target lint .

build: ## Build the frontend bundle only
	pnpm build

windows: ## Cross-compile the portable Windows .exe inside Docker
	docker build \
		--file docker/Dockerfile.windows \
		--target artifact \
		--output type=local,dest=$(OUT_DIR) \
		--tag $(IMAGE) \
		--build-arg CACHEBUST="$$(date +%s)" \
		.
	@ls -lh $(OUT_DIR)/Jotter.exe

clean: ## Remove build output
	rm -rf dist $(OUT_DIR) src-tauri/target src-tauri/gen
