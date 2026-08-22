# Pisaka's front door. Every target here is a shorthand for a command
# documented in CLAUDE.md — the raw commands stay the authority, this file
# stays the convenience.
#
# `hooks` is a prerequisite of every target that does real work, so running
# anything through `make` wires this clone's git hooks in. It is the same
# reasoning the `Wire git hooks` build phase in `project.yml` follows: git
# never enables a repository's hooks by itself, so the wiring has to ride on
# something people already run. Between the two, a contributor who builds the
# app *or* uses make ends up with the gate installed; one who only ever runs
# `swift test` by hand does not, and CI catches them instead.

DESTINATION_MACOS := platform=macOS
DESTINATION_IOS := generic/platform=iOS
PROJECT := Pisaka.xcodeproj
SCHEME := Pisaka

.PHONY: help setup hooks generate test lint build build-ios all

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

setup: hooks ## One-time clone setup: wire the git hooks, then check the linter
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint is not installed. This repository pins the version in"; \
		echo ".swiftlint.yml and the pre-commit hook refuses without that exact"; \
		echo "release — see the Style lint section in README.md."; \
		exit 1; \
	}
	@echo "setup: hooks wired, swiftlint $$(swiftlint version) present."

hooks: ## Point this clone at the repository's tracked hooks
	@git rev-parse --git-dir >/dev/null 2>&1 && git config core.hooksPath .githooks || true

test: hooks ## Run the PisakaCore suite (no dependencies to install)
	swift test

lint: hooks ## Run the style gate exactly as CI runs it
	swiftlint lint --strict

generate: hooks ## Regenerate Pisaka.xcodeproj from project.yml
	xcodegen generate

build: generate ## Build the macOS app in the configuration that ships
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION_MACOS)' -configuration Release build

build-ios: generate ## Build the iOS app for a device (what CI builds)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION_IOS)' build

all: lint test build build-ios ## Everything CI runs, in CI's order
