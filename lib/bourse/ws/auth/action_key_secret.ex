# reach:disable-for-this-file behaviour_candidate — module implements Bourse.WS.Auth.Behaviour; false positive
defmodule Bourse.WS.Auth.ActionKeySecret do
  @moduledoc """
  Plain key/secret authentication for Alpaca's market-data stream.

  Alpaca accepts the credentials in an `action: "auth"` frame and batches its
  success or error response in a JSON array.
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Credentials

  @impl true
  @spec pre_auth(Credentials.t(), map(), keyword()) :: {:ok, map()}
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  @spec build_auth_message(Credentials.t(), map(), keyword()) ::
          {:ok, map()} | {:error, :missing_credentials}
  def build_auth_message(%Credentials{api_key: api_key, secret: secret}, _config, _opts)
      when is_binary(api_key) and is_binary(secret) do
    {:ok, %{"action" => "auth", "key" => api_key, "secret" => secret}}
  end

  def build_auth_message(_credentials, _config, _opts), do: {:error, :missing_credentials}

  @impl true
  @spec handle_auth_response(map() | [map()], map()) :: :ok | {:error, {:auth_failed, term()}}
  def handle_auth_response(frames, _state) when is_list(frames) do
    case Enum.reduce(frames, nil, &auth_outcome/2) do
      :authenticated -> :ok
      {:error, error} -> {:error, {:auth_failed, error}}
      nil -> {:error, {:auth_failed, frames}}
    end
  end

  def handle_auth_response(response, _state), do: {:error, {:auth_failed, response}}

  defp auth_outcome(_frame, :authenticated), do: :authenticated

  defp auth_outcome(frame, outcome) do
    cond do
      authenticated?(frame) -> :authenticated
      error?(frame) -> {:error, frame}
      true -> outcome
    end
  end

  defp authenticated?(%{"T" => "success", "msg" => "authenticated"}), do: true
  defp authenticated?(_frame), do: false

  defp error?(%{"T" => "error"}), do: true
  defp error?(_frame), do: false
end
