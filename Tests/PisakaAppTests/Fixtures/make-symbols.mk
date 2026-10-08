# A plausible project Makefile, written so that every decision
# Resources/Queries/make/symbols.scm makes is exercised at least once:
# ordinary targets are indexed, special (dot-led) and pattern (%) targets are
# not, a `$(VAR):` target is a reference and not a name, and every variable
# definition shape is indexed wherever it sits, including inside conditionals
# and as a target-specific assignment.

CC := cc
CFLAGS ?= -O2
SOURCES = main.c util.c
GIT_SHA != git rev-parse --short HEAD

define BANNER
building $(GIT_SHA)
endef

ifeq ($(CC),cc)
LDFLAGS += -lm
else
LDFLAGS = -lc
endif

.PHONY: build test lint
.SUFFIXES:

build: app
	@echo "$(BANNER)"

test: build
	./app --self-test

lint:
	swiftlint --strict

debug: CFLAGS += -g

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

OUTPUT_DIR = out
$(OUTPUT_DIR):
	mkdir -p $@
