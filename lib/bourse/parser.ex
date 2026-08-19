defmodule Bourse.Parser do
  @moduledoc """
  Public response parser facade.
  """

  alias Bourse.ResponseParser

  @doc """
  Applies a v4 normalization mapping to raw response data.
  """
  @spec apply_mappings(term(), map(), keyword() | map()) ::
          {:ok, struct() | [struct()]} | {:error, term()}
  def apply_mappings(data, mapping, context) do
    ResponseParser.apply_mappings(data, mapping, context)
  end

  @doc """
  Parses `data` against a single normalization-slot mapping into `target`.

  This is the runtime entry point for the generated per-exchange `parse_*`
  functions (`parse_ticker/2`, `parse_trade/2`, …). It applies the **Honesty
  Rule** to the upstream Phase 12 field maps before delegating to
  `apply_mappings/3`:

    * `nil` slot (upstream never derived a field map) → `{:error, :no_field_map}`
    * non-`nil` `_unresolved_reason` (upstream flagged the slot as not safely
      derivable) → `{:error, {:unresolved, reason}}` — the partial field map is
      **not** applied, so callers never receive a struct silently built from an
      incomplete mapping
    * resolved slot with a non-empty `field_map` or `branches` → parsed

  `opts` may carry `:market` (a market-info map), `:symbol`, `:route` (the
  selected endpoint path), `:currencies` (the loaded currency catalog), and
  `:envelope` (the original decoded response); all are threaded into the parser
  context.

  ## Examples

      iex> Bourse.Parser.parse(%{}, nil, Bourse.Ticker)
      {:error, :no_field_map}

      iex> Bourse.Parser.parse(%{}, %{"_unresolved_reason" => "identifier_return"}, Bourse.Market)
      {:error, {:unresolved, "identifier_return"}}

  """
  @spec parse(term(), map() | nil, module(), keyword()) ::
          {:ok, struct() | [struct()]} | {:error, term()}
  def parse(data, mapping, target, opts \\ []) do
    if Keyword.get(opts, :operation_supported, true) do
      parse_supported(data, mapping, target, opts)
    else
      {:error, {:unsupported_operation, Keyword.get(opts, :parse_slot)}}
    end
  end

  defp parse_supported(_data, nil, _target, _opts), do: {:error, :no_field_map}

  defp parse_supported(_data, %{"_unresolved_reason" => reason}, _target, _opts) when not is_nil(reason) do
    {:error, {:unresolved, reason}}
  end

  defp parse_supported(data, mapping, target, opts) when is_map(mapping) do
    if parseable?(mapping) do
      apply_mappings(data, mapping,
        target: target,
        market: Keyword.get(opts, :market, %{}),
        symbol: Keyword.get(opts, :symbol),
        currencies: Keyword.get(opts, :currencies, %{}),
        # networkIdToCode needs the venue's own tables, so `network_code`
        # extraction resolves catalog chains the same way the dispatcher does.
        common_currencies: Keyword.get(opts, :common_currencies, %{}),
        options: Keyword.get(opts, :options, %{}),
        route: Keyword.get(opts, :route),
        venue: Keyword.get(opts, :venue),
        envelope: Keyword.get(opts, :envelope)
      )
    else
      {:error, :no_field_map}
    end
  end

  defp parse_supported(_data, _mapping, _target, _opts), do: {:error, :no_field_map}

  defp parseable?(%{"branches" => branches}) when is_list(branches) and branches != [], do: true
  defp parseable?(%{"field_map" => field_map}) when is_map(field_map) and map_size(field_map) > 0, do: true
  defp parseable?(_mapping), do: false
end
