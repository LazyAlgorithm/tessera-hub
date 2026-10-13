#!/usr/bin/env bash
# Runs a workflow step's script (the "shell: bash <this> {0}" of a step) and, if it fails, repeats the end of its
# output as an error annotation, which shows on the run's summary page without opening the full log.
log="$(mktemp)"
bash -eo pipefail "$1" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
	{ grep -iE "error|failed|fatal|no such|not found|undefined" "$log" | tail -n 12; echo "----"; tail -n 12 "$log"; } | cut -c1-220 | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN { ORS = "%0A" } { print }' | sed 's/^/::error title=Last lines before the failure::/'
	echo
fi
exit "$status"
