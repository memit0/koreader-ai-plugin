#!/bin/sh
# Runs the AskGPT test suite.
#
# Needs a Lua 5.1-compatible interpreter (LuaJIT preferred, as KOReader uses it)
# plus luasql-sqlite3, which stands in for KOReader's lua-ljsqlite3.
#
#   macOS           brew install luajit luarocks
#                   luarocks --lua-version=5.1 install luasql-sqlite3
#   Debian/Ubuntu   apt-get install luajit lua-sql-sqlite3
#
# Override with:  LUA=/path/to/lua ./test/run.sh
cd "$(dirname "$0")" || exit 1

lua="${LUA:-}"
if [ -z "$lua" ]; then
    for candidate in luajit lua5.1 lua51 lua-5.1 lua; do
        if command -v "$candidate" >/dev/null 2>&1; then lua="$candidate"; break; fi
    done
fi
if [ -z "$lua" ]; then
    echo "no Lua interpreter found; install luajit (see the header of this script)" >&2
    exit 1
fi

status=0
for spec in history_spec.lua sync_spec.lua explain_spec.lua failures_spec.lua; do
    output=$("$lua" "$spec" 2>&1)
    summary=$(echo "$output" | grep -E '^[0-9]+ passed')
    if echo "$output" | grep -q "FAIL"; then
        echo "$spec: $summary  <-- FAILURES"
        echo "$output" | grep "FAIL"
        status=1
    else
        echo "$spec: $summary"
    fi
done
rm -rf tmp
exit $status
