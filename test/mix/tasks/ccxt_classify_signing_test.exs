defmodule Mix.Tasks.Ccxt.ClassifySigningTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ccxt.ClassifySigning

  test "prints signing summary and details" do
    output = capture_io(fn -> ClassifySigning.run([]) end)

    assert output =~ "Signing Pattern Classification"
    assert output =~ "Details by Pattern"
    assert output =~ "Total: #{length(Bourse.Spec.exchanges())} exchanges"
    assert output =~ "derive"
    assert output =~ "hyperliquid"
  end
end
