defmodule Mix.Tasks.Bourse.HelpersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.Helpers

  describe "exchange_rows/0" do
    test "returns one row per manifest exchange with signing pattern" do
      rows = Helpers.exchange_rows()

      assert length(rows) == length(Bourse.Spec.exchanges())

      Enum.each(rows, fn row ->
        assert is_binary(row.id)
        assert is_atom(row.signing_pattern)
        assert is_boolean(row.loaded)
        assert is_boolean(row.ws)
      end)
    end
  end

  describe "signing_results/0" do
    test "resolves a pattern for every exchange" do
      results = Helpers.signing_results()

      assert length(results) == length(Bourse.Spec.exchanges())

      Enum.each(results, fn {id, pattern, _config} ->
        assert is_binary(id)
        assert is_atom(pattern)
      end)
    end
  end
end
