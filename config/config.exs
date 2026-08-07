import Config

# The circuit breaker is a production resilience mechanism, and `:fuse` holds its
# state process-globally under a key derived from the exchange id. The offline
# suite drives the same ten ids through failure paths from dozens of unrelated
# modules, so leaving the breaker at its production thresholds couples them: five
# melts inside the 10s window blow the fuse for 15s, and every test that touches
# that venue in the meantime fails with `circuit_open` before its `Req.Test` stub
# is ever called — a red that names neither the venue nor the test that melted it.
#
# Disabling it here removes the ambient coupling rather than the coverage: the
# tests that exist to exercise the breaker re-enable it for themselves through
# `Bourse.Test.CircuitBreakerControl`.
if config_env() == :test do
  config :bourse, :circuit_breaker, %{enabled: false}
end
