# Task 83 — Raw-Endpoint Integration Probe.
#
# Opt-in suite: per-exchange per-auth-class modules, each with module-level
# `:network` + `:raw` + `:exchange_<id>` tags emitted from inside the
# generator. Run with:
#
#     # Public raw endpoints across every registered exchange
#     mix test.json --quiet --include network --only raw --only public
#
#     # Private raw endpoints (needs registered testnet creds)
#     mix test.json --quiet --include network --only raw --only private
#
#     # Include destructive write paths (POST/PUT/DELETE — be careful).
#     # Covers both :public_dangerous (e.g. lighter on-chain sendTx, no
#     # creds needed) and :private_dangerous (authenticated mutations).
#     mix test.json --quiet --include network --include dangerous --only raw
#
#     # One exchange only (all auth classes)
#     mix test.json --quiet --include network --only exchange_bybit
#
# Per-exchange `:private` and `:private_dangerous` modules split at load time:
# exchanges with registered credentials emit the full per-endpoint tests plus a
# runtime `setup_all` backstop; exchanges without registered credentials emit
# one flunk test with the required env-var exports and no `setup_all`. `:public`
# and `:public_dangerous` modules always emit their normal tests.
#
# `Module.create/3` with `quote ... unquote` is needed so the per-iteration
# `exchange_atom` is spliced in as a literal before `use/2` expansion (bare
# `defmodule ... use Mod, exchange: exchange_atom` would pass the AST node
# `{:exchange_atom, _, _}` to `__using__/1`, not the value).

for exchange_id <-
      Bourse.Test.Generator.OptIn.exchanges_for(
        Bourse.Registry.exchanges(),
        [:network, :raw, :dangerous]
      ) do
  exchange_atom = String.to_atom(exchange_id)
  exchange_camel = Macro.camelize(exchange_id)

  for {auth, suffix} <- [
        {:public, PublicTest},
        {:private, PrivateTest},
        {:public_dangerous, PublicDangerousTest},
        {:private_dangerous, PrivateDangerousTest}
      ] do
    module_name = Module.concat([Bourse.Probes.Raw, exchange_camel, suffix])

    Module.create(
      module_name,
      quote do
        use ExUnit.Case, async: false

        use Bourse.Test.Generator.RawEndpointProbe,
          exchange: unquote(exchange_atom),
          auth: unquote(auth)
      end,
      Macro.Env.location(__ENV__)
    )
  end
end
