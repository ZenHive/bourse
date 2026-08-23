defmodule Bourse.RestReadContracts.DeribitTest do
  use ExUnit.Case, async: false
  use Bourse.Test.Generator.RestReadContract, venue: "deribit"
end
