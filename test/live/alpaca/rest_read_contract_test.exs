defmodule Bourse.RestReadContracts.AlpacaTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "alpaca"
end
