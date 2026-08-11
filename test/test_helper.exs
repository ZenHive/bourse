alias Mix.Tasks.Ccxt.BuildLighterSigner

# Integration tests hit live exchange sandboxes and require credentials.
# They never run by accident — include with `mix test --include integration`.
# Network/invalid_creds (T67) hit live exchanges; run with `mix test --include network`.
# capability_live (T188) is the COVERAGE.md standing shortlist gate — live PUBLIC
# per-{venue,method} matrix; include with `--include capability_live` (file-target).
# known_defect marks a test whose assertion is CORRECT but which fails against a
# real, filed product defect — quarantined so the gate stays honest without
# ratifying the bug. Each one names its tracking task inline. Run the set with
# `mix test --include known_defect`; the list must shrink, never grow silently.
if failures_manifest_path = System.get_env("BOURSE_FIXTURE_FAILURES_MANIFEST_PATH") do
  Application.put_env(:ex_unit, :failures_manifest_path, failures_manifest_path)
end

# Stub-driven tests exercise the real retry path against `Req.Test` transport
# errors and 503s, and were paying production exponential backoff to do it —
# over half the suite's wall clock was `Process.sleep`. Zero keeps the retry
# code path (attempt counts, melt decisions, telemetry) fully exercised while
# removing the sleep. Tests that assert real backoff behavior pass their own
# `:retry_delay` per call, which overrides this.
Application.put_env(:bourse, :retry_delay, 0)

# The default offline suite includes the exchange-acceptance oracle gate, which
# replays Lighter's signed accepted-request golden by rebuilding a zk-Schnorr
# signature through the native helper. Build the helper up front when the Go/C
# toolchain is present so the replay has it — `precommit` runs this suite before
# `check.dispatch`'s dedicated `ccxt.check_lighter_signer` step builds it, so a
# cold worktree would otherwise fail the gate. Idempotent: only builds when the
# binary is absent; when the toolchain is unavailable the replay fails loudly.
# Exact executable name — a wildcard would also match build artifacts
# (coverage .gcno/.gcda files) and skip the rebuild with no executable present.
lighter_target = BuildLighterSigner.host_target()

lighter_binary_present? =
  lighter_target
  |> BuildLighterSigner.output_dir()
  |> Path.join(BuildLighterSigner.executable_name(lighter_target))
  |> File.regular?()

if not lighter_binary_present? do
  case Mix.Tasks.Ccxt.CheckLighterSigner.toolchain(&System.find_executable/1) do
    {:ok, _names} -> Mix.Task.run("ccxt.build_lighter_signer")
    {:error, _missing} -> :ok
  end
end

ExUnit.start(
  exclude: [
    :integration,
    :dangerous,
    :network,
    :invalid_creds,
    :capability_live,
    :known_defect,
    :native
  ]
)

# The sandbox credential registry is not an application child (a consumer must
# not boot a test-only ETS registry), so the suite starts it itself. Linked to
# the test_helper process, it lives for the whole run.
{:ok, _testnet} = Bourse.Testnet.start_link([])

# Register testnet credentials for any exchange whose env vars are set.
# T39 private-pipeline probes (UnifiedMethodIntegrationProbe) flunk with
# actionable setup instructions for any exchange not listed here whose
# creds haven't been registered.
#
# Add a supported venue here only after its owned spec exposes a real sandbox
# host/flag.
Bourse.Testnet.register_all_from_env([
  {:bybit, testnet: true},
  {:binance, testnet: true},
  {:binance, :futures, testnet: true},
  {:deribit, testnet: true},
  # Task 210 — Derive testnet (X-Lyra* session-key auth; wallet = api_key)
  {:derive, testnet: true},
  # Task 339 — Hyperliquid testnet (EVM wallet: api_key=address, secret=private key)
  {:hyperliquid, testnet: true}
])

# Venues whose credentials don't follow the {EXCHANGE}_TESTNET_* convention.
# Each register/3 call skips silently when its env vars are absent.

# Alpaca paper-trading keys are the plain ALPACA_API_KEY/SECRET pair.
Bourse.Testnet.register(:alpaca, :default,
  api_key: System.get_env("ALPACA_API_KEY"),
  secret: System.get_env("ALPACA_API_SECRET"),
  sandbox: true
)

# The binancecoinm/binanceusdm demo hosts authenticate with the shared
# BINANCE_FUTURES_TEST(NET) pair (one demo account, two wallets).
binance_futures_key =
  System.get_env("BINANCE_FUTURES_TESTNET_API_KEY") ||
    System.get_env("BINANCE_FUTURES_TEST_API_KEY")

binance_futures_secret =
  System.get_env("BINANCE_FUTURES_TESTNET_API_SECRET") ||
    System.get_env("BINANCE_FUTURES_TEST_API_SECRET")

for exchange <- [:binanceusdm, :binancecoinm] do
  Bourse.Testnet.register(exchange, :default,
    api_key: binance_futures_key,
    secret: binance_futures_secret,
    sandbox: true
  )
end

# OKX international demo trio (www.okx.com + x-simulated-trading: 1).
Bourse.Testnet.register(:okx, :default,
  api_key: System.get_env("OKX_INTL_API_KEY"),
  secret: System.get_env("OKX_INTL_API_SECRET"),
  password: System.get_env("OKX_INTL_PASSPHRASE"),
  sandbox: true
)

# Lighter zk credentials: api_key = key index, uid = account index,
# secret = 40-byte hex API signing key.
Bourse.Testnet.register(:lighter, :default,
  api_key: System.get_env("LIGHTER_TESTNET_API_KEY_INDEX"),
  uid: System.get_env("LIGHTER_TESTNET_ACCOUNT_INDEX"),
  secret: System.get_env("LIGHTER_TESTNET_API_PRIVATE_KEY"),
  sandbox: true
)
