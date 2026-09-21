#!/usr/bin/env bash
# A plausible deploy script, written so that every decision
# Resources/Queries/shell/symbols.scm makes is exercised at least once.
#
# One placement is forced by the pinned grammar rather than by taste. The
# `A=1 B=2` form is `variable_assignments` only while nothing after it can serve
# as the command those assignments prefix: the grammar declares
# `[$.command, $.variable_assignments]` a conflict, and the parser resolves it
# greedily *across newlines* — with any later statement whose first word reads as
# a command name (`readonly`, `echo`, a function call), the whole run collapses
# into `(command (variable_assignment)… (command_name))` and the names stop
# being top-level bindings at all. So `HOST=localhost PORT=8080` is the last
# line of the file, which is the only placement that is stable.
set -euo pipefail

ROOT=/srv/app
readonly RELEASE=v1.2.3
declare -r CHANNEL=stable
export TAG=nightly

greet() {
    local salutation="hello"        # a local: must not be indexed
    GREETING_SEEN=1                 # inside a body: must not be indexed either
    echo "$salutation # not a comment"
}

function announce {
    printf '%s\n' "$RELEASE"
}

deploy() {
    for host in web-1 web-2; do
        attempt=0                   # inside a loop: must not be indexed
        echo "deploying to $host"
    done
}

# A subscript assignment declares no new name: must not be indexed.
arr[2]=x

# Bound elsewhere, assigned nothing here: must not be indexed.
export PATH

greet
announce
deploy

for region in eu us; do
    LAST_REGION=$region             # a top-level loop is still not top level
done

DONE=1
HOST=localhost PORT=8080
