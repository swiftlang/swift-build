#!/bin/bash
set -e

while true ; do
    swift test -vv || (sleep 10 && ls -l ~/Library/Logs/DiagnosticReports/)
done
