#!/usr/bin/env bash

set -uo pipefail

report_dir="${1:-artifacts}"
authority_report="${report_dir}/authority-drift-report.txt"
live_drift_report="${report_dir}/live-drift-report.json"

mkdir -p "${report_dir}"

authority_rc=0
mix ccxt.authority_check --online 2>&1 | tee "${authority_report}" || authority_rc=$?

live_drift_rc=0
mix ccxt.verify_live_drift --report "${live_drift_report}" || live_drift_rc=$?

if ((authority_rc != 0 || live_drift_rc != 0)); then
  echo "Live drift lane failed: authority_rc=${authority_rc} live_drift_rc=${live_drift_rc}" >&2
  exit 1
fi

echo "Live drift lane passed: authority_rc=0 live_drift_rc=0"
