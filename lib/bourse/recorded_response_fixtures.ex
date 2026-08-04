defmodule Bourse.RecordedResponseFixtures do
  @moduledoc """
  Capture support and path resolution for committed reality evidence.

  Covers the venue response recordings under `fixture_root/0` and the real error
  recordings under `error_fixture_root/0`: where they live, how a captured
  fixture is scrubbed before it is committed, and how a persisted case is decoded
  back for replay.

  Replay-exchange construction lives in `Bourse.ReplayExchange`, which is the
  only module that reads the vendored reference market/currency corpus.
  """

  alias Bourse.Credentials
  alias Bourse.JsonDocument
  alias Bourse.RecordedResponseFixtures.Capture

  @doc "Loads and decodes a fixture JSON file."
  @spec load_fixture!(String.t()) :: map()
  def load_fixture!(path) do
    JsonDocument.decode_file!(path)
  end

  @doc "Infers a coarse market-type label from a fixture case (for coverage reporting)."
  @spec infer_market_type(map()) :: String.t()
  def infer_market_type(case_data) when is_map(case_data) do
    cond do
      swap_symbol?(case_data) -> "swap"
      inverse_symbol?(case_data) -> "inverse"
      spot_symbol?(case_data) -> "spot"
      fapi_url?(case_data) -> "swap"
      dapi_url?(case_data) -> "inverse"
      api_url?(case_data) -> "spot"
      true -> "unknown"
    end
  end

  defp swap_symbol?(case_data) do
    case_data
    |> input_symbols()
    |> Enum.any?(fn symbol ->
      is_binary(symbol) and String.contains?(symbol, ":") and
        not String.ends_with?(symbol, ":BTC")
    end)
  end

  defp inverse_symbol?(case_data) do
    case_data
    |> input_symbols()
    |> Enum.any?(fn symbol -> is_binary(symbol) and String.ends_with?(symbol, ":BTC") end)
  end

  defp spot_symbol?(case_data) do
    case_data
    |> input_symbols()
    |> Enum.any?(fn symbol ->
      is_binary(symbol) and not String.contains?(symbol, ":")
    end)
  end

  defp input_symbols(case_data) do
    case_data
    |> Map.get("input", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp fapi_url?(case_data), do: url_fragment?(case_data, "fapi")
  defp dapi_url?(case_data), do: url_fragment?(case_data, "dapi")
  defp api_url?(case_data), do: url_fragment?(case_data, "api.binance.com")

  defp url_fragment?(case_data, fragment) do
    case_data
    |> Map.get("url", "")
    |> to_string()
    |> String.contains?(fragment)
  end

  @doc "Returns every `{venue, method}` pair supported by the live capture pipeline."
  @spec capture_targets() :: [{String.t(), atom()}]
  defdelegate capture_targets(), to: Capture, as: :targets

  @doc "Returns the capture category for a configured target."
  @spec capture_category(String.t(), atom()) :: Capture.category() | nil
  defdelegate capture_category(exchange_id, method), to: Capture, as: :category

  @doc "Returns stable oracle identity fields for a configured target."
  @spec oracle_identity(String.t(), atom()) :: map() | nil
  defdelegate oracle_identity(exchange_id, method), to: Capture

  @doc "Root directory for legacy recorded response fixtures."
  @spec fixture_root() :: String.t()
  def fixture_root do
    __DIR__
    |> Path.join("../../test/fixtures/responses")
    |> Path.expand()
  end

  @doc "Root directory for committed real error recordings."
  @spec error_fixture_root() :: String.t()
  defdelegate error_fixture_root(), to: Capture

  @doc "Absolute path for a legacy recorded response fixture file."
  @spec fixture_path(String.t(), atom()) :: String.t()
  def fixture_path(exchange_id, method) when is_binary(exchange_id) and is_atom(method) do
    case capture_category(exchange_id, method) do
      :error -> Capture.error_fixture_path(exchange_id, method)
      _other -> Path.join([fixture_root(), exchange_id, "#{method}.json"])
    end
  end

  @doc "Decodes persisted `call_opts` from a legacy fixture JSON map."
  @spec decode_call_opts(map()) :: keyword()
  def decode_call_opts(fixture) do
    fixture
    |> Map.get("call_opts", %{})
    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  @doc "Captures and scrubs one configured live response fixture."
  @spec capture_fixture(String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture_fixture(exchange_id, method, call_opts \\ []) do
    Capture.capture_fixture(exchange_id, method, call_opts)
  end

  @doc "Returns the environment variables required by one capture target."
  @spec required_credentials(String.t(), atom()) :: [String.t()] | nil
  defdelegate required_credentials(exchange_id, method), to: Capture

  @doc "Recursively masks credential and account identity material in a fixture."
  @spec scrub_fixture(term(), Credentials.t() | nil) :: term()
  defdelegate scrub_fixture(value, credentials \\ nil), to: Capture, as: :scrub

  @doc "Returns corpus paths whose sensitive fields are not masked."
  @spec safety_violations(term()) :: [String.t()]
  defdelegate safety_violations(value), to: Capture
end
