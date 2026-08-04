defmodule Bourse.TestExchange.Bybit do
  @moduledoc "Test exchange module generated from bybit spec (2 visibility levels)."
  use Bourse.Exchange, spec: "bybit"
end

defmodule Bourse.TestExchange.Binance do
  @moduledoc "Test exchange module generated from binance spec (multiple API sections)."
  use Bourse.Exchange, spec: "binance"
end
