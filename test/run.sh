#!/bin/sh
# Runs the AskGPT test suite.
#
# Needs lua5.1 and luasql-sqlite3, which stand in for the LuaJIT and
# lua-ljsqlite3 that KOReader ships:
#     apt-get install lua5.1 lua-sql-sqlite3
#
# The plugin's own code runs unmodified; only KOReader's modules are stubbed.
cd "$(dirname "$0")" || exit 1
status=0
for spec in history_spec.lua sync_spec.lua explain_spec.lua failures_spec.lua; do
    output=$(lua5.1 "$spec" 2>&1)
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
