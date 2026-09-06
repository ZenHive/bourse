defmodule Bourse.CheckDispatchConfigTest do
  use ExUnit.Case, async: true

  @reach_command "cmd env MIX_ENV=dev mix reach.check --arch --smells --strict --path lib"
  @authority_commands ["bourse.authority_check", "bourse.error_authority"]

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
    assert Enum.any?(
             alias_steps(:ci),
             &(&1 =~ "cmd env MIX_ENV=test mix bourse.verify_rest_read_contracts")
           )
  end

  test "check aliases name Mix tasks under bourse.*, not ccxt.*" do
    steps = Enum.flat_map([:precommit, :"check.dispatch", :"precommit.full", :ci], &alias_steps/1)

    refute Enum.any?(steps, &String.starts_with?(&1, "ccxt."))

    assert Enum.filter(steps, &String.starts_with?(&1, "bourse.")) == [
             "bourse.check_lighter_signer",
             "bourse.authority_check",
             "bourse.error_authority",
             "bourse.claude_check",
             "bourse.agents_md --check"
           ]
  end

  test "check.dispatch builds the Lighter helper before the suite that loads it" do
    steps = alias_steps(:"check.dispatch")

    signer = Enum.find_index(steps, &(&1 == "bourse.check_lighter_signer"))
    suite = Enum.find_index(steps, &(&1 == "precommit"))

    assert is_integer(signer) and is_integer(suite)

    assert signer < suite,
           "precommit runs the :native tests against priv/native/lighter_signer/, which is a " <>
             "gitignored build artifact. Ordering the suite first lets a stale binary red the " <>
             "gate on operations it predates — a red with no defect."
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

  test "docs do not autolink deliberately filtered internals" do
    skipped_references =
      Bourse.MixProject.project()
      |> Keyword.fetch!(:docs)
      |> Keyword.fetch!(:skip_code_autolink_to)

    assert skipped_references == [
             "Bourse.LiveLane.Bootstrap",
             "Bourse.LiveLane.FirstFrame"
           ]
  end
end
