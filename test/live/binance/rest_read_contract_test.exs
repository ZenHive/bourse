defmodule Bourse.RestReadContracts.BinanceTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "binance"
end
