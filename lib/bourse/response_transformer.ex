defmodule Bourse.ResponseTransformer do
  @moduledoc """
  Response shape normalization applied *before* field-mapping extraction.

  Some exchanges return responses in wire shapes the unified parsers don't expect.
  For example:

  - BitMEX returns `[%{ticker}]` instead of `%{ticker}` for `fetch_ticker`
  - BitMEX returns a flat order list instead of `%{bids: [], asks: []}` for `fetch_order_book`
  - Deribit OHLCV is column-oriented (`%{"open" => [...], "close" => [...]}`) rather than rows

  ## Scope relative to authored `normalization.response_envelopes`

  Authored specs carry per-method **envelope key paths** (e.g. `key: "result"`
  with `fallback_keys`/`default`). That covers the simple "reach into the response
  envelope" cases the `:extract_path*` family handled manually in the reference
  implementation — prefer the authored envelopes for those.

  This module retains the residual transforms that are **not** expressible as a
  static envelope key path because they reshape the wire data itself:
  list/map unwrapping, flat-list → order-book, positional-array → maps,
  column-oriented → rows, and composition. The `:extract_path*` variants are
  kept too, for per-exchange overrides and `:compose` chains where an envelope
  hop must precede a reshape.

  ## Usage

  Configure a `:response_transformer` on an endpoint config; `Bourse.Dispatch`
  applies it to the response body before the body reaches the parser:

      %{
        name: :fetch_order_book,
        path: "/orderBook/L2",
        response_transformer: :order_book_from_flat_list
      }

  Available transformers:

  - `{:extract_path, path}` — extracts nested data via key path
  - `{:extract_path_unwrap, path}` — extracts via path, then unwraps single-element list (`nil` for empty list)
  - `{:extract_path_unwrap_map, path}` — extracts via path, then unwraps single-key map to its value
  - `{:extract_path_unwrap_merge, path, merge_keys}` — like `:extract_path_unwrap`, merging envelope keys into the result (inner fields win via `put_new`)
  - `:unwrap_single_element_list` — unwraps `[item]` to `item` (returns `[]` for empty list)
  - `:unwrap_single_element_map` — unwraps `%{key => value}` to `value` (0 or 2+ key maps unchanged)
  - `:extract_first_list_value` — first value that is a list in a map (ignores metadata keys like `"last"`)
  - `:order_book_from_flat_list` — converts a flat order list to `%{bids: [], asks: []}`
  - `{:positional_to_maps, field_names}` — converts inner positional arrays to maps by zipping with field names
  - `{:transpose_columns_to_rows, column_keys}` — transposes column-oriented map to a list of rows
  - `{:compose, [transformer]}` — chains transformers left-to-right
  """

  require Logger

  @type transformer ::
          :unwrap_single_element_list
          | :unwrap_single_element_map
          | :extract_first_list_value
          | :order_book_from_flat_list
          | {:extract_path, [String.t()]}
          | {:extract_path_unwrap, [String.t()]}
          | {:extract_path_unwrap_map, [String.t()]}
          | {:extract_path_unwrap_merge, [String.t()], [String.t()]}
          | {:positional_to_maps, [String.t()]}
          | {:transpose_columns_to_rows, [String.t()]}
          | {:compose, [transformer()]}
          | nil

  @doc """
  Applies a transformer to the response body.

  Returns the transformed body, or the original body if no transformer is specified.
  """
  @spec transform(term(), transformer()) :: term()
  def transform(body, nil), do: body
  def transform(body, :unwrap_single_element_list), do: unwrap_single_element_list(body)
  def transform(body, :order_book_from_flat_list), do: order_book_from_flat_list(body)
  def transform(body, {:extract_path, path}) when is_list(path), do: extract_path(body, path)

  # Note: unlike bare :unwrap_single_element_list (which returns [] for empty input),
  # extract_path_unwrap returns nil for empty lists — signaling "no data" after envelope extraction.
  def transform(body, {:extract_path_unwrap, path}) when is_list(path) do
    case body |> extract_path(path) |> unwrap_single_element_list() do
      [] -> nil
      other -> other
    end
  end

  def transform(body, {:extract_path_unwrap_merge, path, merge_keys}) when is_list(path) and is_list(merge_keys) do
    case body |> extract_path(path) |> unwrap_single_element_list() do
      [] -> nil
      %{} = result -> merge_envelope_fields(body, result, merge_keys)
      other -> other
    end
  end

  def transform(body, :unwrap_single_element_map), do: unwrap_single_element_map(body)
  def transform(body, :extract_first_list_value), do: extract_first_list_value(body)

  def transform(body, {:extract_path_unwrap_map, path}) when is_list(path) do
    body |> extract_path(path) |> unwrap_single_element_map()
  end

  def transform(body, {:positional_to_maps, field_names}) when is_list(field_names) do
    positional_to_maps(body, field_names)
  end

  def transform(body, {:compose, transformers}) when is_list(transformers) do
    Enum.reduce(transformers, body, fn t, acc -> transform(acc, t) end)
  end

  def transform(body, {:transpose_columns_to_rows, keys}) when is_list(keys) do
    transpose_columns_to_rows(body, keys)
  end

  def transform(body, unknown) do
    Logger.warning("[ResponseTransformer] Unknown transformer: #{inspect(unknown)}, returning body unchanged")

    body
  end

  @doc """
  Unwraps a single-element list to its element.

  Used when an API returns `[item]` but the unified API expects `item`.

  ## Examples

      iex> Bourse.ResponseTransformer.unwrap_single_element_list([%{"symbol" => "BTC"}])
      %{"symbol" => "BTC"}

      iex> Bourse.ResponseTransformer.unwrap_single_element_list([])
      []

      iex> Bourse.ResponseTransformer.unwrap_single_element_list([%{a: 1}, %{b: 2}])
      [%{a: 1}, %{b: 2}]

  """
  @spec unwrap_single_element_list(term()) :: term()
  def unwrap_single_element_list([single]) when is_map(single), do: single
  def unwrap_single_element_list(other), do: other

  @doc """
  Unwraps a single-key map to its value.

  Used when an API returns `%{"KEY" => value}` but the unified API expects `value`
  directly. E.g., Kraken's /public/Ticker returns `{"result": {"XXBTUSD": {...}}}`
  where the key is the symbol name (not a meaningful container).

  Returns maps with 0 or 2+ keys unchanged.

  ## Examples

      iex> Bourse.ResponseTransformer.unwrap_single_element_map(%{"XXBTUSD" => %{"a" => [1]}})
      %{"a" => [1]}

      iex> Bourse.ResponseTransformer.unwrap_single_element_map(%{})
      %{}

      iex> Bourse.ResponseTransformer.unwrap_single_element_map(%{"a" => 1, "b" => 2})
      %{"a" => 1, "b" => 2}

      iex> Bourse.ResponseTransformer.unwrap_single_element_map("not a map")
      "not a map"

  """
  @spec unwrap_single_element_map(term()) :: term()
  def unwrap_single_element_map(%{} = map) when map_size(map) == 1 do
    [{_key, value}] = :maps.to_list(map)
    value
  end

  def unwrap_single_element_map(other), do: other

  @doc """
  Extracts the first list value from a map, ignoring non-list metadata keys.

  Used when an API returns a map with a dynamic data key alongside metadata keys.
  E.g., Kraken's fetch_trades returns `%{"XXBTZUSD" => [[...trades...]], "last" => "1541439421"}`
  where `"last"` is metadata and the pair key holds the actual data.

  Returns the map unchanged when no list values exist.

  ## Examples

      iex> Bourse.ResponseTransformer.extract_first_list_value(%{"XXBTZUSD" => [[1], [2]], "last" => "123"})
      [[1], [2]]

      iex> Bourse.ResponseTransformer.extract_first_list_value(%{"XXBTZUSD" => [[1]]})
      [[1]]

      iex> Bourse.ResponseTransformer.extract_first_list_value(%{"a" => 1, "b" => 2})
      %{"a" => 1, "b" => 2}

      iex> Bourse.ResponseTransformer.extract_first_list_value("not a map")
      "not a map"

  """
  @spec extract_first_list_value(term()) :: term()
  def extract_first_list_value(%{} = map) do
    case Enum.find(map, fn {_key, value} -> is_list(value) end) do
      {_key, list_value} -> list_value
      nil -> map
    end
  end

  def extract_first_list_value(other), do: other

  @doc """
  Converts a flat order list to structured order book format.

  BitMEX returns orders as a flat list with a "side" field:
  `[%{"side" => "Sell", "price" => 100, "size" => 10}, %{"side" => "Buy", ...}]`

  This transforms it to unified format:
  `%{"bids" => [[price, size], ...], "asks" => [[price, size], ...]}`

  ## Examples

      iex> orders = [
      ...>   %{"side" => "Sell", "price" => 100.5, "size" => 10},
      ...>   %{"side" => "Buy", "price" => 99.5, "size" => 20}
      ...> ]
      iex> Bourse.ResponseTransformer.order_book_from_flat_list(orders)
      %{"bids" => [[99.5, 20]], "asks" => [[100.5, 10]]}

  """
  @spec order_book_from_flat_list(term()) :: term()
  def order_book_from_flat_list(orders) when is_list(orders) do
    {bids, asks} =
      Enum.reduce(orders, {[], []}, fn order, {bids, asks} ->
        price = order["price"]
        size = order["size"]

        case order["side"] do
          "Buy" -> {[[price, size] | bids], asks}
          "Sell" -> {bids, [[price, size] | asks]}
          # Skip unknown sides
          _ -> {bids, asks}
        end
      end)

    # Bids sorted descending (highest first), asks sorted ascending (lowest first)
    %{
      "bids" => Enum.sort_by(bids, fn [price, _] -> price end, :desc),
      "asks" => Enum.sort_by(asks, fn [price, _] -> price end, :asc)
    }
  end

  def order_book_from_flat_list(other), do: other

  @doc """
  Transposes column-oriented data into a list of rows.

  Some exchanges (e.g., Deribit OHLCV) return data as a map of columns:
  `%{"ticks" => [1, 2], "open" => [10, 20]}` instead of rows `[[1, 10], [2, 20]]`.

  Column keys determine the order of elements in each row. Missing keys or
  non-list column values cause the data to be returned unchanged (defensive).

  ## Examples

      iex> Bourse.ResponseTransformer.transpose_columns_to_rows(
      ...>   %{"a" => [1, 2], "b" => [3, 4]},
      ...>   ["a", "b"]
      ...> )
      [[1, 3], [2, 4]]

      iex> Bourse.ResponseTransformer.transpose_columns_to_rows("not a map", ["a"])
      "not a map"

  """
  @spec transpose_columns_to_rows(term(), [String.t()]) :: term()
  def transpose_columns_to_rows(%{} = data, [_ | _] = column_keys) do
    columns = Enum.map(column_keys, &Map.get(data, &1))

    if Enum.all?(columns, &is_list/1) do
      columns |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
    else
      data
    end
  end

  def transpose_columns_to_rows(data, _column_keys), do: data

  @doc """
  Converts positional arrays in a list to maps by zipping with field names.

  Used when an API returns trades (or similar) as positional arrays instead of maps.
  E.g., Kraken's fetchTrades returns `[["50000", "0.01", 1710327959, "b", "m", "", 123], ...]`

  ## Examples

      iex> Bourse.ResponseTransformer.positional_to_maps(
      ...>   [["50000", "0.01", "b"], ["51000", "0.02", "s"]],
      ...>   ["price", "amount", "side"]
      ...> )
      [%{"price" => "50000", "amount" => "0.01", "side" => "b"}, %{"price" => "51000", "amount" => "0.02", "side" => "s"}]

      iex> Bourse.ResponseTransformer.positional_to_maps("not a list", ["a"])
      "not a list"

  """
  @spec positional_to_maps(term(), [String.t()]) :: term()
  def positional_to_maps(rows, field_names) when is_list(rows) do
    Enum.map(rows, fn
      row when is_list(row) ->
        field_names
        |> Enum.zip(row)
        |> Map.new()

      other ->
        other
    end)
  end

  def positional_to_maps(other, _field_names), do: other

  @doc """
  Extracts nested data from a response envelope using a key path.

  Walks into nested maps following the given keys. Returns the data at the
  final key, or the current level's data if a key is not found (i.e., stops
  walking and returns whatever map it reached).

  ## Examples

      iex> body = %{"retCode" => 0, "result" => %{"list" => [[1, 2, 3]]}}
      iex> Bourse.ResponseTransformer.extract_path(body, ["result", "list"])
      [[1, 2, 3]]

      iex> Bourse.ResponseTransformer.extract_path(%{"data" => "test"}, [])
      %{"data" => "test"}

      iex> Bourse.ResponseTransformer.extract_path(%{"a" => 1}, ["missing"])
      %{"a" => 1}

      iex> Bourse.ResponseTransformer.extract_path(%{"result" => %{"data" => "test"}}, ["result", "missing"])
      %{"data" => "test"}

  """
  @spec extract_path(term(), [String.t()]) :: term()
  def extract_path(data, []), do: data

  def extract_path(%{} = data, [key | rest]) do
    case Map.get(data, key) do
      nil -> data
      value -> extract_path(value, rest)
    end
  end

  def extract_path(data, [index | rest]) when is_list(data) and is_binary(index) do
    case Integer.parse(index) do
      {parsed_index, ""} when parsed_index >= 0 ->
        case Enum.fetch(data, parsed_index) do
          {:ok, value} -> extract_path(value, rest)
          :error -> data
        end

      _ ->
        data
    end
  end

  def extract_path(data, _path), do: data

  # Merges specified keys from the envelope into the extracted result.
  # Uses put_new so inner data fields always win over envelope fields.
  @spec merge_envelope_fields(term(), map(), [String.t()]) :: map()
  defp merge_envelope_fields(%{} = envelope, result, merge_keys) do
    Enum.reduce(merge_keys, result, fn key, acc ->
      case Map.get(envelope, key) do
        nil -> acc
        value -> Map.put_new(acc, key, value)
      end
    end)
  end

  defp merge_envelope_fields(_envelope, result, _merge_keys), do: result
end
