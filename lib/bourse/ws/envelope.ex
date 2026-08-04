defmodule Bourse.WS.Envelope do
  @moduledoc """
  Builds WS message envelope config for routing inbound frames.

  Reads `websocket.dispatch.discriminators` from the exchange spec and merges
  authored per-exchange envelope overrides (data field, unwrap_list,
  match_type).
  """

  alias Bourse.Exchange

  @type envelope :: %{
          optional(String.t()) => term()
        }

  # Authored per-exchange envelope paths.
  @overrides %{
    "binance" => %{
      "discriminator_field" => "e",
      "data_field" => "self",
      "match_type" => "exact"
    },
    "binanceusdm" => %{
      "discriminator_field" => "e",
      "data_field" => "self",
      "match_type" => "exact"
    },
    "bybit" => %{
      "discriminator_field" => "topic",
      "data_field" => "data",
      "unwrap_list" => false,
      "match_type" => "exact_then_substring"
    },
    "deribit" => %{
      "discriminator_field" => "params.channel",
      "data_field" => "params.data",
      "unwrap_list" => false,
      "match_type" => "split"
    },
    "derive" => %{
      "discriminator_field" => "channel",
      "data_field" => "data",
      "match_type" => "split"
    },
    "hyperliquid" => %{
      "discriminator_field" => "channel",
      "data_field" => "data",
      "match_type" => "exact_then_substring"
    },
    "okx" => %{
      "discriminator_field" => "arg.channel",
      "data_field" => "data",
      "unwrap_list" => true,
      "match_type" => "exact",
      "prefix_channels" => ["candle"]
    }
  }

  @doc "Returns envelope config for an exchange, or nil when routing is unavailable."
  @spec for_exchange(Exchange.t()) :: envelope() | nil
  def for_exchange(%Exchange{id: id, spec: spec}) do
    case Map.get(@overrides, id) do
      nil ->
        nil

      override ->
        dispatch = get_in(spec, ["websocket", "dispatch"]) || %{}

        if dispatch["kind"] == "none" do
          nil
        else
          override
          |> maybe_put_discriminator(dispatch)
          |> Map.put("discriminators", Map.get(dispatch, "discriminators", []))
        end
    end
  end

  @doc "Returns the match strategy for an exchange envelope."
  @spec match_type(envelope() | nil) :: String.t()
  def match_type(nil), do: "exact"
  def match_type(envelope), do: Map.get(envelope, "match_type", "exact")

  @doc "Returns prefix channel keys that need prefix matching (e.g. OKX `candle`)."
  @spec prefix_channels(envelope() | nil) :: [String.t()]
  def prefix_channels(nil), do: []
  def prefix_channels(envelope), do: Map.get(envelope, "prefix_channels", [])

  defp maybe_put_discriminator(envelope, dispatch) do
    Map.put_new(envelope, "discriminator_field", pick_discriminator(dispatch["discriminators"]))
  end

  defp pick_discriminator(nil), do: nil
  defp pick_discriminator([]), do: nil
  defp pick_discriminator([head | _]), do: head
end
