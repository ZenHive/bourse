defmodule Mix.Tasks.Bourse.ClassifySigning do
  @shortdoc "Report signing pattern classification for all exchanges"

  @moduledoc """
  Reports signing pattern resolution for all exchanges.

  Loads every compiled exchange spec, resolves its declared signing pattern via
  `auth.sign_recipe`, and prints a summary grouped by pattern.

  ## Usage

      mix bourse.classify_signing

  """

  use Mix.Task

  alias Mix.Tasks.Bourse.Helpers

  @impl true
  def run(_args) do
    results = Helpers.signing_results()

    Helpers.print_pattern_section("Signing Pattern Classification", results, details_title: "Details by Pattern")
  end
end
