defmodule Bourse.WS.MessageRouter do
  @moduledoc """
  Routes decoded WS frames to payload families using envelope extraction.

  Channel → family resolution reads `websocket.dispatch` via `Bourse.WS.Dispatch`.
  """

  alias Bourse.Exchange
  alias Bourse.WS.Dispatch
  alias Bourse.WS.Envelope

  @type route_result ::
          {:routed, atom(), term(), String.t()}
          | {:system, map()}
          | {:unknown, map()}

  @doc "Routes a decoded WS message for an exchange."
  @spec route(map(), Exchange.t()) :: route_result()
  def route(raw_msg, %Exchange{} = exchange) when is_map(raw_msg) do
    envelope = Envelope.for_exchange(exchange)

    case envelope do
      nil -> {:unknown, raw_msg}
      envelope -> route(raw_msg, envelope, exchange)
    end
  end

  @doc "Routes a decoded WS message using an explicit envelope config."
  @spec route(map(), map() | nil, Exchange.t()) :: route_result()
  def route(raw_msg, nil, _exchange), do: {:unknown, raw_msg}

  def route(raw_msg, envelope, %Exchange{} = exchange) when is_map(raw_msg) and is_map(envelope) do
    case extract_channel(raw_msg, envelope) do
      nil ->
        if response_message?(raw_msg), do: {:system, raw_msg}, else: {:unknown, raw_msg}

      channel ->
        resolve_family(raw_msg, envelope, exchange, channel)
    end
  end

  @spec resolve_family(map(), map(), Exchange.t(), String.t()) :: route_result()
  defp resolve_family(raw_msg, envelope, exchange, channel) do
    case Dispatch.resolve_channel(exchange, channel) do
      {:family, family} ->
        payload = extract_data(raw_msg, envelope)
        {:routed, family, payload, channel}

      :system ->
        {:system, raw_msg}

      :not_found ->
        {:unknown, raw_msg}
    end
  end

  @spec response_message?(map()) :: boolean()
  defp response_message?(%{"id" => _, "result" => _}), do: true
  defp response_message?(_), do: false

  @doc "Extracts the channel name using the envelope's `discriminator_field`."
  @spec extract_channel(map(), map()) :: String.t() | nil
  def extract_channel(raw_msg, envelope) do
    field = Map.get(envelope, "discriminator_field")

    case get_nested(raw_msg, field) do
      channel when is_binary(channel) and channel != "" ->
        channel

      _absent ->
        match_shape_channel(raw_msg, envelope)
    end
  end

  @doc "Extracts payload data using the envelope's `data_field`."
  @spec extract_data(map(), map()) :: term()
  def extract_data(raw_msg, envelope) do
    data =
      case Map.get(envelope, "data_field") do
        "self" -> raw_msg
        field -> get_nested(raw_msg, field)
      end

    if Map.get(envelope, "unwrap_list") do
      unwrap_single_element_list(data)
    else
      data
    end
  end

  @doc "Resolves a dot-notation path in a nested map."
  @spec get_nested(map(), String.t() | nil) :: term()
  def get_nested(_map, nil), do: nil

  def get_nested(map, path) when is_map(map) and is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(map, fn key, acc ->
      case acc do
        %{} = m -> {:cont, Map.get(m, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  def get_nested(_, _), do: nil

  @spec match_shape_channel(map(), map()) :: String.t() | nil
  defp match_shape_channel(raw_msg, envelope) when is_map(raw_msg) do
    envelope
    |> Envelope.shape_channels()
    |> Enum.find_value(fn shape ->
      channel = Map.get(shape, "channel")

      if is_binary(channel) and channel != "" and shape_match?(raw_msg, shape) do
        channel
      end
    end)
  end

  defp shape_match?(raw_msg, %{"required" => keys}) when is_list(keys) do
    Enum.all?(keys, fn key ->
      Map.has_key?(raw_msg, key) and shape_value_ok?(key, Map.fetch!(raw_msg, key))
    end)
  end

  defp shape_match?(_raw_msg, _shape), do: false

  defp shape_value_ok?(key, value) when key in ["bids", "asks"], do: is_list(value)
  defp shape_value_ok?(_key, value), do: not is_nil(value)

  @non_market_segments ~w(raw snapshot update 100ms)

  @doc "Extracts a market id segment from a dot-delimited channel string."
  @spec extract_market_id(String.t() | nil) :: String.t() | nil
  def extract_market_id(nil), do: nil

  def extract_market_id(channel) when is_binary(channel) do
    channel
    |> String.split(".")
    |> Enum.find(&market_id_segment?/1)
  end

  defp market_id_segment?(segment) do
    byte_size(segment) >= 3 and
      segment not in @non_market_segments and
      not numeric?(segment) and
      market_id_chars_only?(segment)
  end

  defp numeric?(s), do: match?({_, ""}, Integer.parse(s))

  defp market_id_chars_only?(s), do: Regex.match?(~r/^[A-Z0-9\-_]+$/, s)

  @spec unwrap_single_element_list(term()) :: term()
  defp unwrap_single_element_list([single]), do: single
  defp unwrap_single_element_list(other), do: other
end
