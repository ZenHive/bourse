defmodule Bourse.WS.Auth.Eip191JsonrpcLogin do
  @moduledoc """
  EIP-191 JSON-RPC login — derive `public/login`.

  Signs the millisecond timestamp with EIP-191 personal signing (the same
  primitive as Derive's REST `X-LyraSignature`) and wraps it in a JSON-RPC
  `public/login` frame. `wallet` is the smart-contract wallet (`api_key` /
  `X-LyraWallet`); `secret` is a registered Admin session key.

  Live-verified 2026-08-28 against `wss://api-demo.lyra.finance/ws`: a
  successful login returns the session's subaccount ids in `result`.

  ## Example Frame

      %{
        "id" => 1,
        "method" => "public/login",
        "params" => %{
          "wallet" => "0x…",
          "timestamp" => "1700000000000",
          "signature" => "0x…"
        }
      }

  ## Config / opts

  | Key | Location | Default | Purpose |
  |---|---|---|---|
  | `:method_value` | `config` | `"public/login"` | RPC method override |
  | `:request_id` | `opts` | `System.unique_integer([:positive])` | RPC `id` |
  | `:timestamp_ms_override` | `config` | (unset) | Test-only — freezes the clock |
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Signing
  alias Bourse.Signing.Derive

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(credentials, config, opts) do
    timestamp = timestamp_string(config)
    signature = Derive.sign_message(timestamp, private_key: credentials.secret)
    request_id = opts[:request_id] || System.unique_integer([:positive])

    {:ok,
     %{
       "id" => request_id,
       "method" => Map.get(config, :method_value, "public/login"),
       "params" => %{
         "wallet" => credentials.api_key,
         "timestamp" => timestamp,
         "signature" => signature
       }
     }}
  end

  @impl true
  def handle_auth_response(%{"error" => error}, _state) when not is_nil(error) do
    {:error, {:auth_failed, error}}
  end

  def handle_auth_response(%{"result" => result}, _state) when is_list(result) do
    {:ok, %{subaccounts: result}}
  end

  def handle_auth_response(response, _state) do
    {:error, {:auth_failed, response}}
  end

  defp timestamp_string(config) do
    case Signing.timestamp_ms_from_config(config) do
      ms when is_integer(ms) -> Integer.to_string(ms)
      ts when is_binary(ts) -> ts
    end
  end
end
