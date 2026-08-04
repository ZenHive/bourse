defmodule Bourse.CheckDispatchConfigTest do
  use ExUnit.Case, async: true

  @reach_command "cmd env MIX_ENV=dev mix reach.check --arch --smells --strict --path lib"
  @oracle_command "cmd env MIX_ENV=test mix ccxt.oracle_gate"

  test "check.dispatch uses the reality oracle as its only oracle step" do
    steps =
      Bourse.MixProject.project()
      |> Keyword.fetch!(:aliases)
      |> Keyword.fetch!(:"check.dispatch")

    oracle_steps = Enum.filter(steps, &String.contains?(&1, "oracle"))

    assert oracle_steps == [@oracle_command]
  end

  test "check.dispatch pins Reach to the lib source tree" do
    reach_steps =
      Bourse.MixProject.project()
      |> Keyword.fetch!(:aliases)
      |> Keyword.fetch!(:"check.dispatch")
      |> Enum.filter(&String.contains?(&1, "reach.check"))

    assert reach_steps == [@reach_command]
  end
end
