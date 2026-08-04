defmodule Bourse.WS.Semantics.Orderbook do
  @moduledoc """
  Orderbook snapshot/delta state driven by `websocket.orderbook_semantics`.
  """

  alias Bourse.Exchange

  @type t :: %__MODULE__{
          apply_mode: String.t(),
          discriminator_field: String.t() | nil,
          snapshot_values: [String.t()],
          delta_values: [String.t()],
          sequence_fields: [String.t()],
          checksum_present: boolean(),
          books: %{String.t() => map()}
        }

  defstruct apply_mode: "none",
            discriminator_field: nil,
            snapshot_values: [],
            delta_values: [],
            sequence_fields: [],
            checksum_present: false,
            books: %{}

  @doc "Builds state from exchange spec semantics."
  @spec new(Exchange.t()) :: t()
  def new(%Exchange{spec: spec}) do
    semantics = get_in(spec, ["websocket", "orderbook_semantics"]) || %{}

    discriminator = Map.get(semantics, "discriminator", %{})

    %__MODULE__{
      apply_mode: Map.get(semantics, "apply_mode", "none"),
      discriminator_field: Map.get(discriminator, "field"),
      snapshot_values: Map.get(discriminator, "snapshot_values", []),
      delta_values: Map.get(discriminator, "delta_values", []),
      sequence_fields: Map.get(semantics, "sequence_fields", []),
      checksum_present: get_in(semantics, ["checksum", "present"]) == true
    }
  end

  @doc "Applies a routed orderbook payload and returns updated state + book snapshot."
  @spec apply(t(), String.t(), term()) :: {t(), map() | nil}
  def apply(%__MODULE__{apply_mode: "none"} = state, _key, _payload), do: {state, nil}

  def apply(%__MODULE__{} = state, key, payload) when is_binary(key) do
    mode = classify_update(state, payload)
    book = Map.get(state.books, key, empty_book())

    case mode do
      :snapshot ->
        new_book = snapshot_book(payload)
        {%{state | books: Map.put(state.books, key, new_book)}, new_book}

      :delta ->
        updated = apply_delta(book, payload)
        {%{state | books: Map.put(state.books, key, updated)}, updated}

      :replace ->
        new_book = replace_book(payload)
        {%{state | books: Map.put(state.books, key, new_book)}, new_book}

      :unknown ->
        {state, Map.get(state.books, key)}
    end
  end

  @spec classify_update(t(), term()) :: :snapshot | :delta | :replace | :unknown
  defp classify_update(%__MODULE__{apply_mode: mode} = state, payload) do
    case mode do
      "snapshot" -> :snapshot
      "delta" -> :delta
      "replace" -> :replace
      "both" -> classify_both(state, payload)
      _ -> :unknown
    end
  end

  defp classify_both(%__MODULE__{discriminator_field: field, snapshot_values: snapshots}, payload)
       when is_map(payload) and is_binary(field) do
    value = Map.get(payload, field)

    cond do
      value in snapshots -> :snapshot
      value == "delta" or value == "update" -> :delta
      snapshots != [] -> :delta
      true -> :unknown
    end
  end

  defp classify_both(%__MODULE__{}, _payload), do: :unknown

  defp empty_book, do: %{"bids" => [], "asks" => []}

  defp snapshot_book(payload) when is_map(payload) do
    %{
      "bids" => Map.get(payload, "b", Map.get(payload, "bids", [])),
      "asks" => Map.get(payload, "a", Map.get(payload, "asks", []))
    }
  end

  defp snapshot_book(payload), do: %{"payload" => payload}

  defp replace_book(payload), do: snapshot_book(payload)

  defp apply_delta(book, payload) when is_map(payload) do
    bids = merge_levels(Map.get(book, "bids", []), Map.get(payload, "b", Map.get(payload, "bids", [])))
    asks = merge_levels(Map.get(book, "asks", []), Map.get(payload, "a", Map.get(payload, "asks", [])))
    %{"bids" => bids, "asks" => asks}
  end

  defp apply_delta(book, payload), do: Map.put(book, "payload", payload)

  defp merge_levels(existing, updates) when is_list(existing) and is_list(updates) do
    Enum.reduce(updates, existing, fn level, acc -> merge_level(acc, level) end)
  end

  defp merge_levels(existing, _), do: existing

  defp merge_level(acc, [price, size]) do
    if zero_size?(size) do
      Enum.reject(acc, fn [p, _] -> p == price end)
    else
      upsert_level(acc, price, size)
    end
  end

  defp merge_level(acc, _level), do: acc

  defp zero_size?(size), do: size in ["0", 0, 0.0]

  defp upsert_level(acc, price, size) do
    case Enum.find_index(acc, fn [p, _] -> p == price end) do
      nil -> acc ++ [[price, size]]
      idx -> List.replace_at(acc, idx, [price, size])
    end
  end
end
