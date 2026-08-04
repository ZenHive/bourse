defmodule Bourse.Exchanges do
  @moduledoc """
  Compile-time generator for every supported exchange module.

  Reads the spec manifest and generates one module per exchange
  (e.g., `Bourse.Bybit`, `Bourse.Binance`) at compile time via `Module.create/3`.

  The closed runtime-support manifest is the only module inventory.

  ## How it works

  The manifest lists all exchange IDs. For each ID, this module calls
  `Bourse.Exchange.prepare_generate_data/1` to build the AST, then creates
  the module directly — same pipeline as `use Bourse.Exchange`, but without
  needing individual stub files.
  """

  alias Bourse.Exchanges.Loader

  @manifest_path Bourse.Spec.manifest_path()
  @external_resource @manifest_path

  @exchange_ids Bourse.Spec.exchanges()

  for id <- @exchange_ids do
    module_name = Module.concat(Bourse, Macro.camelize(id))
    data = Bourse.Exchange.prepare_generate_data(id)
    moduledoc = Bourse.Exchange.build_exchange_moduledoc(data)
    body = Bourse.Exchange.build_module_body(data, moduledoc: moduledoc)

    Loader.create(module_name, body, Macro.Env.location(__ENV__))
  end
end
