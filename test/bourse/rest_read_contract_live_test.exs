for venue <- Bourse.Test.RestReadContracts.venues() do
  module = Module.concat([Bourse.RestReadContracts, Macro.camelize(venue) <> "Test"])

  Module.create(
    module,
    quote do
      use ExUnit.Case, async: false
      use Bourse.Test.Generator.RestReadContract, venue: unquote(venue)
    end,
    Macro.Env.location(__ENV__)
  )
end
