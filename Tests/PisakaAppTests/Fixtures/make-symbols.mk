# A plausible project Makefile exercising every decision symbols.scm makes:
# ordinary targets are indexed (a dot-led file target, every target of a
# multi-target or double-colon rule, a suffix-shaped target with prerequisites
# or of a static-pattern rule); special names, prerequisite-less suffix rules,
# pattern (%) targets and `$(VAR):` references are not; every variable shape
# is indexed wherever it sits (conditionals, export/override/private, target-
# specific, VPATH) unless it names a special variable, whatever defines it.
#

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

.BUILD: build
	touch $@

VPATH = src

.SUFFIXES: .c .o
.c.o:
	$(CC) $(CFLAGS) -c $<

.SHELLSTATUS := 0

.lm.c:
	lex -t $< > $@

.yl:
	touch $@

.c.o: config.h

.s.o: | out
	$(AS) -o $@ $<

.S.o: %.o: %.S
	$(CC) -c $<

.EXTRA_PREREQS != printf tools
define .FEATURES
none
endef
