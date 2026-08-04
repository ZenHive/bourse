# Task 89 — dangerous unified write-method integration probe.
#
# Opt-in requires both tags:
#
#     mix test.json --quiet --include network --include dangerous --only unified_integration
#
# These tests never use default assets. Each emitted test first loads
# `Bourse.Test.AssetConfig` for `{exchange_id, method}` and flunks loudly when
# the asset is absent. Order-write probes create and cancel in the same test
# body to avoid accumulating open orders on shared testnet accounts.

for exchange_id <-
      Bourse.Test.Generator.OptIn.exchanges_for(
        Bourse.Registry.exchanges(),
        [:network, :dangerous, :unified_integration]
      ) do
  exchange_atom = String.to_atom(exchange_id)
  exchange_camel = Macro.camelize(exchange_id)
  module_name = Module.concat([Bourse.Probes.UnifiedWrite, exchange_camel, PrivateDangerousTest])

  Module.create(
    module_name,
    quote do
      use ExUnit.Case, async: false

      use Bourse.Test.Generator.UnifiedWriteMethodIntegrationProbe,
        exchange: unquote(exchange_atom),
        auth: :private_dangerous
    end,
    Macro.Env.location(__ENV__)
  )
end
