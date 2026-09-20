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

  defp expanded_steps(name) do
    aliases = Keyword.fetch!(Bourse.MixProject.project(), :aliases)

    Enum.flat_map(alias_steps(name), fn step ->
      case Enum.find(Keyword.keys(aliases), &(Atom.to_string(&1) == step)) do
        nil -> [step]
        nested -> expanded_steps(nested)
      end
    end)
  end

  test "dispatch expands to formatting and compilation only" do
    assert expanded_steps(:"check.dispatch") == [
             "format --check-formatted",
             "compile --warnings-as-errors"
           ]

    joined = Enum.join(expanded_steps(:"check.dispatch"), "\n")

    for needle <- ["credo", "doctor", "sobelow", "dialyzer", "reach", "ex_dna", "test.json", "--cover"] do
      refute joined =~ needle, "check.dispatch must not invoke #{needle}"
    end
  end

  test "CLAUDE.md imports the canonical verification-policy include" do
    claude = File.read!("CLAUDE.md")

    assert claude =~ ~r/^@~\/\.claude\/includes\/verification-policy\.md$/m
    assert File.exists?("priv/agents_includes/verification-policy.md")
  end

  test "check.full retains the former dispatch analyzer graph" do
    refute "check.dispatch" in alias_steps(:"check.full")

    assert expanded_steps(:"check.full") == [
             "bourse.check_lighter_signer",
             "format --check-formatted",
             "compile --warnings-as-errors",
             "credo --strict --ignore TagTODO,TagFIXME",
             "doctor --raise",
             "sobelow --skip",
             "cmd env MIX_ENV=test mix test.json --quiet",
             "bourse.authority_check",
             "bourse.error_authority",
             "bourse.claude_check",
             "bourse.agents_md --check",
             "ex_dna --max-clones 0",
             @reach_command
           ]
  end

  test "ci retains the complete QA graph independently of dispatch" do
    refute "check.dispatch" in alias_steps(:ci)

    assert expanded_steps(:ci) == [
             "bourse.check_lighter_signer",
             "format --check-formatted",
             "compile --warnings-as-errors",
             "credo --strict --ignore TagTODO,TagFIXME",
             "doctor --raise",
             "sobelow --skip",
             "cmd env MIX_ENV=test mix test.json --quiet",
             "bourse.authority_check",
             "bourse.error_authority",
             "bourse.claude_check",
             "bourse.agents_md --check",
             "ex_dna --max-clones 0",
             @reach_command,
             "cmd env MIX_ENV=test mix bourse.verify_rest_read_contracts",
             "cmd env MIX_ENV=test mix test.json --quiet --cover --cover-threshold 80 --output /tmp/bourse-ci-cover.json",
             "deps.audit --ignore-advisory-ids GHSA-w4f7-4cxr-rv3c",
             "dialyzer.json --quiet"
           ]
  end

  test "precommit.full retains its suite and audit steps" do
    assert expanded_steps(:"precommit.full") ==
             expanded_steps(:precommit) ++
               ["deps.audit --ignore-advisory-ids GHSA-w4f7-4cxr-rv3c", "dialyzer.json --quiet"]
  end

  test "no gate replays a recording as an oracle" do
    steps = Enum.flat_map([:precommit, :"check.dispatch", :"check.full", :"precommit.full", :ci], &alias_steps/1)

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
    steps = Enum.flat_map([:precommit, :"check.dispatch", :"check.full", :"precommit.full", :ci], &alias_steps/1)

    refute Enum.any?(steps, &String.starts_with?(&1, "ccxt."))

    assert Enum.filter(steps, &String.starts_with?(&1, "bourse.")) == [
             "bourse.check_lighter_signer",
             "bourse.authority_check",
             "bourse.error_authority",
             "bourse.claude_check",
             "bourse.agents_md --check"
           ]
  end

  test "check.full builds the Lighter helper before the suite that loads it" do
    steps = alias_steps(:"check.full")

    signer = Enum.find_index(steps, &(&1 == "bourse.check_lighter_signer"))
    suite = Enum.find_index(steps, &(&1 == "precommit"))

    assert is_integer(signer) and is_integer(suite)

    assert signer < suite,
           "precommit runs the :native tests against priv/native/lighter_signer/, which is a " <>
             "gitignored build artifact. Ordering the suite first lets a stale binary red the " <>
             "gate on operations it predates — a red with no defect."
  end

  test "check.full pins Reach to the lib source tree" do
    reach_steps =
      Bourse.MixProject.project()
      |> Keyword.fetch!(:aliases)
      |> Keyword.fetch!(:"check.full")
      |> Enum.filter(&String.contains?(&1, "reach.check"))

    assert reach_steps == [@reach_command]
  end

  test "check.full runs both authority checks offline" do
    steps =
      Bourse.MixProject.project()
      |> Keyword.fetch!(:aliases)
      |> Keyword.fetch!(:"check.full")

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
