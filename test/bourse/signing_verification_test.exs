defmodule Bourse.SigningVerificationTest do
  @moduledoc """
  Per-exchange offline signing verification tests, generated at compile
  time from `Bourse.Registry.exchanges/0` + each module's `__signing__/0`.

  See `Bourse.Test.Generator.SigningTests` for the generator macro.
  """

  use ExUnit.Case, async: true
  use Bourse.Test.Generator.SigningTests
end
