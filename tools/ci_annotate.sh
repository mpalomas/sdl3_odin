#!/usr/bin/env bash
# Runs a command and, when it fails, reports the end of its output as one error annotation of the workflow run: the annotation is
# on the run's page, and the GitHub API shows it without a login, which a job's log needs.
#
#   tools/ci_annotate.sh <title> <command> [args...]

set -uo pipefail

title=$1
shift
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [[ $status -ne 0 ]]; then
    # An annotation's message is one line: %, carriage returns and line feeds are escaped.
    message="$(tail -n 60 "$log" | cut -c1-300 | tr -d '\r' | sed -e 's/%/%25/g' | awk '{ printf "%s%%0A", $0 }')"
    echo "::error title=$title failed, exit $status::$message"
fi
rm -f "$log"
exit "$status"
