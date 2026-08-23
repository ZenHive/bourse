defmodule Bourse.RestReadContracts.HyperliquidTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "hyperliquid"
end
