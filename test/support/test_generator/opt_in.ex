defmodule Bourse.Test.Generator.OptIn do
  @moduledoc """
  Keeps compile-time integration probe generation behind explicit ExUnit filters.

  Ordinary offline runs load the lightweight test files without creating the
  per-exchange/per-endpoint modules. Explicit suite or exchange filters retain
  the complete selected probe surface.
  """

  @doc "Returns whether the current ExUnit include filters request an opt-in suite."
  @spec requested?([atom()]) :: boolean()
  def requested?(suite_tags) when is_list(suite_tags) do
    requested_from?(Keyword.get(ExUnit.configuration(), :include, []), suite_tags)
  end

  @doc "Returns whether include filters select a suite tag or an exchange tag."
  @spec requested_from?(keyword() | [atom()], [atom()]) :: boolean()
  def requested_from?(include, suite_tags) when is_list(include) and is_list(suite_tags) do
    Enum.any?(suite_tags, &included?(include, &1)) or selected_exchange_ids(include) != []
  end

  @doc "Returns selected exchanges for the current filters, or `[]` when the suite is not requested."
  @spec exchanges_for([String.t()], [atom()]) :: [String.t()]
  def exchanges_for(catalog, suite_tags) when is_list(catalog) and is_list(suite_tags) do
    exchanges_for(catalog, suite_tags, Keyword.get(ExUnit.configuration(), :include, []))
  end

  @doc false
  @spec exchanges_for([String.t()], [atom()], keyword() | [atom()]) :: [String.t()]
  def exchanges_for(catalog, suite_tags, include) when is_list(catalog) and is_list(suite_tags) and is_list(include) do
    if requested_from?(include, suite_tags) do
      case selected_exchange_ids(include) do
        [] -> catalog
        selected -> Enum.filter(catalog, &(&1 in selected))
      end
    else
      []
    end
  end

  defp selected_exchange_ids(include) do
    include
    |> Enum.flat_map(fn
      {tag, value} when is_atom(tag) and value != false -> exchange_id(tag)
      tag when is_atom(tag) -> exchange_id(tag)
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp exchange_id(tag) do
    case Atom.to_string(tag) do
      "exchange_" <> exchange_id when exchange_id != "" -> [exchange_id]
      _other -> []
    end
  end

  defp included?(include, tag) do
    Enum.any?(include, fn
      {^tag, value} -> value != false
      ^tag -> true
      _other -> false
    end)
  end
end
