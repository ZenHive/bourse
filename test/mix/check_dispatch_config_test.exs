defmodule Bourse.CheckDispatchConfigTest do
  use ExUnit.Case, async: true

  @reach_command "cmd env MIX_ENV=dev mix reach.check --arch --smells --strict --path lib"
  @authority_commands ["ccxt.authority_check", "ccxt.error_authority"]

  defp alias_steps(name) do
    Bourse.MixProject.project()
    |> Keyword.fetch!(:aliases)
    |> Keyword.fetch!(name)
    |> List.wrap()
  end

  test "no gate replays a recording as an oracle" do
    steps = Enum.flat_map([:precommit, :"check.dispatch", :"precommit.full", :ci], &alias_steps/1)

    assert Enum.filter(steps, &(&1 =~ ~r/oracle|record_fixtures|accepted_requests|replay/)) == []
  end

  test "the suite step carries no tag exclusion" do
    for name <- [:precommit, :ci],
        step <- alias_steps(name),
        step =~ "test.json" do
      refute step =~ "--exclude",
             "#{name} excludes tags from the suite: #{step}. A live lane that opts out " <>
               "of its own venues reports a green that covers nothing."
    end
  end

  test "ci runs the full provider-live REST-read contract lane" do
    assert "ccxt.verify_rest_read_contracts" in alias_steps(:ci)
  end

  test "check.dispatch pins Reach to the lib source tree" do
    reach_steps =
      Bourse.MixProject.project()
      |> Keyword.fetch!(:aliases)
      |> Keyword.fetch!(:"check.dispatch")
      |> Enum.filter(&String.contains?(&1, "reach.check"))

    assert reach_steps == [@reach_command]
  end

  test "check.dispatch runs both authority checks offline" do
    steps =
      Bourse.MixProject.project()
      |> Keyword.fetch!(:aliases)
      |> Keyword.fetch!(:"check.dispatch")

    assert Enum.filter(steps, &(&1 in @authority_commands)) == @authority_commands
    refute Enum.any?(steps, &String.contains?(&1, "authority_check --online"))
  end
end
