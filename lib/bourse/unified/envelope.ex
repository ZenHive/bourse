defmodule Bourse.Unified.Envelope do
  @moduledoc false
  # Unwraps unified read response bodies using spec `response_envelopes`.

  alias Bourse.ResponseTransformer

  @type unwrap_result :: {:ok, term()} | {:error, term()}

  @doc "Unwraps a raw HTTP body to the payload shape parsers expect."
  @spec unwrap(term(), module(), String.t(), String.t(), String.t(), boolean()) :: unwrap_result()
  def unwrap(body, module, _exchange_id, parse_type, js_name, list_return?) do
    with {:ok, payload} <- resolve_payload(body, module, parse_type, js_name, list_return?) do
      {:ok, coerce_return_shape(payload, list_return?)}
    end
  end

  defp resolve_payload(body, module, parse_type, js_name, list_return?) do
    if list_return? and is_list(body) do
      {:ok, body}
    else
      case spec_envelope(body, module, parse_type, js_name) do
        {:ok, payload} when list_return? and not is_list(payload) ->
          {:ok, body}

        {:ok, payload} ->
          {:ok, payload}

        :no_spec_envelope ->
          {:ok, body}

        :empty_list_envelope when list_return? ->
          {:ok, []}

        :empty_list_envelope ->
          {:ok, body}
      end
    end
  end

  defp spec_envelope(body, module, parse_type, js_name) do
    case envelope_config(module, parse_type, js_name) do
      %{"key" => key} = config when is_binary(key) ->
        extract_configured_payload(body, envelope_keys(key, config), Map.get(config, "default"))

      _ ->
        :no_spec_envelope
    end
  end

  # No key yielded rows. An empty list at a present key is a valid empty
  # success for list returns (empty positions/orders/trades), not a reason
  # to hand the raw envelope to the parser.
  defp extract_configured_payload(body, keys, default) do
    {payload, saw_empty_list} =
      Enum.reduce_while(keys, {nil, false}, fn key, {_acc, saw_empty} ->
        case extract_envelope_key(body, key, default) do
          {:ok, value} ->
            {:halt, {value, saw_empty}}

          :miss ->
            {:cont, {nil, saw_empty or empty_list_at_key?(body, key)}}
        end
      end)

    cond do
      not is_nil(payload) -> {:ok, payload}
      saw_empty_list -> :empty_list_envelope
      true -> {:ok, body}
    end
  end

  defp empty_list_at_key?(body, key) when is_map(body) do
    path = String.split(key, ".")
    Map.has_key?(body, hd(path)) and ResponseTransformer.extract_path(body, path) == []
  end

  defp empty_list_at_key?(_body, _key), do: false

  defp envelope_keys(primary_key, config) do
    [primary_key | Map.get(config, "fallback_keys", [])]
  end

  # A non-map body carries no envelope key at all — Binance's linear
  # `fetchMarginMode` (`GET /fapi/v1/positionRisk`) answers with a bare row
  # list while its inverse sibling answers with a `positions[]` envelope, so a
  # configured key must miss rather than probe the list for a map key.
  defp extract_envelope_key(body, _key, _default) when not is_map(body), do: :miss

  defp extract_envelope_key(body, key, default) do
    path = String.split(key, ".")
    extracted = ResponseTransformer.extract_path(body, path)

    cond do
      extracted == body and path != [] and not Map.has_key?(body, hd(path)) ->
        :miss

      is_nil(extracted) ->
        :miss

      empty_envelope_payload?(extracted, default) ->
        :miss

      true ->
        {:ok, extracted}
    end
  end

  # Empty list under a key whose default is not already `[]` means "no rows
  # here — try fallbacks" (lighter fetchTicker: primary key may be [] while
  # the other market class holds the row). When default is `[]` (list-return
  # markets/tickers), an empty list is a valid empty success.
  defp empty_envelope_payload?([], default), do: default != []
  defp empty_envelope_payload?(%{}, []), do: true
  defp empty_envelope_payload?(_extracted, _default), do: false

  defp envelope_config(module, parse_type, js_name) do
    case module.__response_envelopes__() do
      %{} = envelopes ->
        case Map.get(envelopes, parse_type) do
          %{} = slot -> Map.get(slot, js_name)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp coerce_return_shape(payload, true), do: payload

  defp coerce_return_shape([single], false) when is_map(single), do: single

  defp coerce_return_shape([], false), do: []

  defp coerce_return_shape(payload, false), do: payload
end
