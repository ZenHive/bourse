defmodule Bourse.RestReadContracts.OkxTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "okx"
end
