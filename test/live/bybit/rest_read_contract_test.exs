defmodule Bourse.RestReadContracts.BybitTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "bybit"
end
