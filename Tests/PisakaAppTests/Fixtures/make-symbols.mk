# A plausible project Makefile, written so that every decision
# Resources/Queries/make/symbols.scm makes is exercised at least once:
# ordinary targets are indexed (an ordinary dot-led file target included, and
# every target of a multi-target or double-colon rule), special names (a dot
# and capitals) and pattern (%) targets are not, a `$(VAR):` target is a
# reference and not a name, and every variable definition shape is indexed
# wherever it sits, including inside conditionals, under export/override/
# private and as a target-specific assignment.

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

.DEFAULT_GOAL := build
export PREFIX = /usr/local
override CFLAGS += -Wall
private STAMP = .stamp

install uninstall: build
	@echo $@

clean::
	rm -f app

.venv: requirements.txt
	python3 -m venv $@
