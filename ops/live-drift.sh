#!/usr/bin/env bash

set -uo pipefail

report_dir="${1:-artifacts}"
authority_report="${report_dir}/authority-drift-report.txt"
live_drift_report="${report_dir}/live-drift-report.json"
corpus_report="${report_dir}/live-corpus-report.json"
auth_smoke_report="${report_dir}/ws-auth-smoke-dangerous-report.json"
ws_report="${report_dir}/ws-first-frame-report.json"
lane_report="${report_dir}/live-lane-report.json"

mkdir -p "${report_dir}"

authority_rc=0
mix ccxt.authority_check --online 2>&1 | tee "${authority_report}" || authority_rc=$?

live_drift_rc=0
mix ccxt.verify_live_drift --report "${live_drift_report}" || live_drift_rc=$?

# Generated probe suites compile when `:network` is included; the excludes keep
# them from executing. `:dangerous` stays out of the corpus so the weekly lane
# does not place orders except the listen-key file targeted below.
corpus_rc=0
mix test.json --quiet \
  --include network \
  --include capability_live \
  --include integration \
  --exclude dangerous \
  --exclude raw \
  --exclude public_probe \
  --exclude unified_integration \
  --exclude invalid_creds \
  --exclude symbol_public_probe \
  --output "${corpus_report}" || corpus_rc=$?

# Task 643 class: listen-key sockets connect and stay silent until an account
# event. The existing auth smoke drives that event on testnet/demo only.
auth_smoke_rc=0
mix test.json --quiet \
  --include network \
  --include dangerous \
  --output "${auth_smoke_report}" \
  test/bourse/ws/auth_live_smoke_test.exs || auth_smoke_rc=$?

ws_rc=0
mix ccxt.verify_ws_first_frame --report "${ws_report}" || ws_rc=$?

aggregate_rc=0
mix ccxt.aggregate_live_lane \
  --report "${lane_report}" \
  --authority "${authority_report}" \
  --authority-rc "${authority_rc}" \
  --drift "${live_drift_report}" \
  --corpus "${corpus_report}" \
  --auth-smoke "${auth_smoke_report}" \
  --ws "${ws_report}" || aggregate_rc=$?

if ((authority_rc != 0 || live_drift_rc != 0 || corpus_rc != 0 || auth_smoke_rc != 0 || ws_rc != 0 || aggregate_rc != 0)); then
  echo "Live lane failed: authority_rc=${authority_rc} live_drift_rc=${live_drift_rc} corpus_rc=${corpus_rc} auth_smoke_rc=${auth_smoke_rc} ws_rc=${ws_rc} aggregate_rc=${aggregate_rc}" >&2
  exit 1
fi

echo "Live lane passed: authority_rc=0 live_drift_rc=0 corpus_rc=0 auth_smoke_rc=0 ws_rc=0 aggregate_rc=0"
