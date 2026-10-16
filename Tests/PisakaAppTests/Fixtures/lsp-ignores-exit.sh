#!/bin/sh
# A stand-in language server for LSPProcessShutdownTests (D43): it answers
# `initialize` and nothing else, ignores `exit` and stdin EOF, and records
# SIGTERM in the marker file named by $1 without dying of it — so only the
# transport's SIGKILL, one grace later, ever ends it.
marker="$1"
trap 'echo term > "$marker"' TERM

# Wait for the end of the first request's headers, so the reply cannot
# overtake the request it answers.
while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r')
    [ -z "$line" ] && break
done
body='{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}'
printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"

# Never read again, never leave. `sleep` is short so the trap runs promptly.
while :; do sleep 0.05; done
