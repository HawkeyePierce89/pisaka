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

# The Xcode every `xcodebuild` below runs under — the one CI and the release
# workflow pin (docs/RELEASING.md). A newer local toolchain accepts code the
# pinned one refuses, so the app-layer gates are only worth running under this
# one. Override from the command line or the environment to point at another
# copy of the same release; `toolchain` refuses when it is missing, or is some
# other release, rather than falling back to whatever xcode-select names. The
# version itself is `override`, so `make PINNED_XCODE_VERSION=…` cannot move
# the release `toolchain` checks against — only the path is a caller's choice.
override PINNED_XCODE_VERSION := 26.3
PINNED_XCODE ?= /Applications/Xcode_$(PINNED_XCODE_VERSION).app

.PHONY: help setup hooks toolchain generate test test-app lint build build-ios all

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

toolchain: hooks ## Refuse unless the Xcode CI pins is installed at PINNED_XCODE
	@test -d "$(PINNED_XCODE)/Contents/Developer" || { \
		echo "The pinned Xcode is missing: $(PINNED_XCODE)"; \
		echo "It is the Xcode CI and the release workflow build with (docs/RELEASING.md),"; \
		echo "and make never falls back to the system-selected one. Install it there, or point"; \
		echo "make at another copy of the same release:"; \
		echo "  make test-app PINNED_XCODE=/path/to/$(notdir $(PINNED_XCODE))"; \
		exit 1; \
	}
	@actual="$$(DEVELOPER_DIR="$(PINNED_XCODE)/Contents/Developer" xcodebuild -version | head -n 1)"; \
	test "$$actual" = "Xcode $(PINNED_XCODE_VERSION)" || { \
		echo "$(PINNED_XCODE) is $$actual, not the pinned Xcode $(PINNED_XCODE_VERSION)."; \
		echo "A different release proves nothing about what CI accepts; point PINNED_XCODE="; \
		echo "at a copy of Xcode $(PINNED_XCODE_VERSION) instead."; \
		exit 1; \
	}

test: hooks ## Run the PisakaCore suite (no dependencies to install)
	swift test

test-app: toolchain generate ## Run the app-layer test bundle (PisakaAppTests)
	DEVELOPER_DIR="$(PINNED_XCODE)/Contents/Developer" xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION_MACOS)' test

lint: hooks ## Run the style gate exactly as CI runs it
	swiftlint lint --strict

generate: hooks ## Regenerate Pisaka.xcodeproj from project.yml
	xcodegen generate

build: toolchain generate ## Build the macOS app in the configuration that ships
	DEVELOPER_DIR="$(PINNED_XCODE)/Contents/Developer" xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION_MACOS)' -configuration Release build

build-ios: toolchain generate ## Build the iOS app for a device (what CI builds)
	DEVELOPER_DIR="$(PINNED_XCODE)/Contents/Developer" xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION_IOS)' build

all: lint test test-app build build-ios ## Everything CI runs, in CI's order
