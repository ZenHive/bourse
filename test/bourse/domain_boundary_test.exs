defmodule Bourse.DomainBoundaryTest do
  @moduledoc """
  The trading domain may depend on the exchange client; the client must never
  depend on the trading domain.

  The domain layer (`Bourse.OptionProposal`, `Bourse.OptionReadiness`,
  `Bourse.OptionSaga`, `Bourse.PortfolioRisk`) lives in this repo for now but is
  not part of the client's surface — `mix.exs` keeps it out of the package. As
  long as the dependency stays one-directional, moving it into its own repo is a
  file move rather than a refactor; a single inbound edge turns it into one.

  The guard was introduced while the invariant already held, so it costs no
  refactor. It scans `lib/` only: that is where the architectural boundary lives,
  and venue integration tests legitimately exercise domain code.
  """

  use ExUnit.Case, async: true

  @domain_prefixes ~w(option_proposal option_readiness option_saga portfolio_risk)
  @domain_modules ~w(OptionProposal OptionReadiness OptionSaga PortfolioRisk)

  test "no client module depends on the trading domain" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&domain_file?/1)
      |> Enum.flat_map(&domain_references/1)

    assert offenders == [],
           """
           The client must not depend on the trading domain — these references
           would turn a later extraction into a refactor:

           #{Enum.map_join(offenders, "\n", fn {file, mod} -> "  #{file} -> #{mod}" end)}
           """
  end

  defp domain_file?(path) do
    rest = Path.relative_to(path, "lib/bourse")
    Enum.any?(@domain_prefixes, &(rest == "#{&1}.ex" or String.starts_with?(rest, "#{&1}/")))
  end

  # Walks the AST rather than the raw source so that prose in comments and
  # moduledocs naming a domain module is not mistaken for a dependency.
  defp domain_references(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:__aliases__, _meta, [:Bourse, mod | _rest]} = node, acc when is_atom(mod) ->
        if Atom.to_string(mod) in @domain_modules do
          {node, [{path, "Bourse.#{mod}"} | acc]}
        else
          {node, acc}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
  end
end
