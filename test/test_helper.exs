alias Mix.Tasks.Bourse.BuildLighterSigner

# This suite is provider-live. There is no default tag exclusion and no offline
# substitute: a venue we cannot reach, or a credential we do not hold, is a RED
# with actionable setup text — never a silent skip. `critical-rules.md`
# § LIVE E2E FIRST is the standing rule; `:dangerous` is the one opt-in gate,
# because a mutating probe must be requested deliberately.
if failures_manifest_path = System.get_env("BOURSE_FIXTURE_FAILURES_MANIFEST_PATH") do
  Application.put_env(:ex_unit, :failures_manifest_path, failures_manifest_path)
end

# The native Lighter signer is required by the zk-signing path. Build it up front
# when the Go/C toolchain is present; idempotent, and a missing toolchain lets the
# signing tests fail loudly rather than silently not running.
lighter_target = BuildLighterSigner.host_target()

lighter_binary_present? =
  lighter_target
  |> BuildLighterSigner.output_dir()
  |> Path.join(BuildLighterSigner.executable_name(lighter_target))
  |> File.regular?()

if not lighter_binary_present? do
  case Mix.Tasks.Bourse.CheckLighterSigner.toolchain(&System.find_executable/1) do
    {:ok, _names} -> Mix.Task.run("bourse.build_lighter_signer")
    {:error, _missing} -> :ok
  end
end

ExUnit.start(exclude: [:dangerous])

# The sandbox credential registry is not an application child (a consumer must
# not boot a test-only ETS registry), so the suite starts it itself. Linked to
# the test_helper process, it lives for the whole run.
{:ok, _testnet} = Bourse.Testnet.start_link([])

# Every venue below MUST register. `Bourse.Testnet.register/3` answers `:skipped`
# when its env vars are absent — that is a legitimate library answer, but for this
# suite it is a setup failure, so it is raised here instead of quietly shrinking
# the live surface. Venues whose credentials follow the {EXCHANGE}_TESTNET_*
# convention:
env_registrations = [
  {:bybit, [testnet: true]},
  {:binance, [testnet: true]},
  {:binance, :futures, [testnet: true]},
  {:deribit, [testnet: true]},
  # Task 210 — Derive testnet (X-Lyra* session-key auth; wallet = api_key)
  {:derive, [testnet: true]},
  # Task 339 — Hyperliquid testnet (EVM wallet: api_key=address, secret=private key)
  {:hyperliquid, [testnet: true]}
]

# Venues whose credentials don't follow that convention. Alpaca paper-trading
# uses the plain pair; binancecoinm/binanceusdm share one demo account across two
# wallets; OKX uses the international demo trio; Lighter uses zk key/account
# indices plus a 40-byte hex signing key.
binance_futures_key =
  System.get_env("BINANCE_FUTURES_TESTNET_API_KEY") ||
    System.get_env("BINANCE_FUTURES_TEST_API_KEY")

binance_futures_secret =
  System.get_env("BINANCE_FUTURES_TESTNET_API_SECRET") ||
    System.get_env("BINANCE_FUTURES_TEST_API_SECRET")

explicit_registrations =
  [
    {:alpaca,
     [
       api_key: System.get_env("ALPACA_API_KEY"),
       secret: System.get_env("ALPACA_API_SECRET"),
       sandbox: true
     ]},
    {:okx,
     [
       api_key: System.get_env("OKX_INTL_API_KEY"),
       secret: System.get_env("OKX_INTL_API_SECRET"),
       password: System.get_env("OKX_INTL_PASSPHRASE"),
       sandbox: true
     ]},
    {:lighter,
     [
       api_key: System.get_env("LIGHTER_TESTNET_API_KEY_INDEX"),
       uid: System.get_env("LIGHTER_TESTNET_ACCOUNT_INDEX"),
       secret: System.get_env("LIGHTER_TESTNET_API_PRIVATE_KEY"),
       sandbox: true
     ]}
  ] ++
    for exchange <- [:binanceusdm, :binancecoinm] do
      {exchange, [api_key: binance_futures_key, secret: binance_futures_secret, sandbox: true]}
    end

registration_results =
  Enum.map(env_registrations, fn
    {exchange, opts} ->
      {exchange, :default, Bourse.Testnet.register_from_env(exchange, :default, opts)}

    {exchange, sandbox_key, opts} ->
      {exchange, sandbox_key, Bourse.Testnet.register_from_env(exchange, sandbox_key, opts)}
  end) ++
    Enum.map(explicit_registrations, fn {exchange, opts} ->
      {exchange, :default, Bourse.Testnet.register(exchange, :default, opts)}
    end)

unregistered =
  for {exchange, sandbox_key, result} <- registration_results, result != :ok do
    "  #{exchange}/#{sandbox_key} -> #{inspect(result)}"
  end

if unregistered != [] do
  raise """
  Provider-live credentials are missing; this suite has no offline mode.

  #{Enum.join(unregistered, "\n")}

  Every venue above needs its testnet/demo credentials exported before the suite
  can make a statement about it. The per-venue variable names and signup URLs are
  in CLAUDE.md § Venue authority index. Running without them would report a green
  that covers nothing, which is the exact failure this suite exists to prevent.
  """
end
