defmodule Bourse.RestReadContracts.BinanceusdmTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "binanceusdm"
end
