defmodule Bourse.RestReadContracts.DeriveTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "derive"
end
