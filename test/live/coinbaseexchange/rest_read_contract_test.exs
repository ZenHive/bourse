defmodule Bourse.RestReadContracts.CoinbaseexchangeTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "coinbaseexchange"
end
