defmodule Mix.Tasks.Ccxt.ReferenceCorpus do
  @moduledoc """
  Repository-only access to the version-pinned CCXT reference corpus.

  Runtime support is owned by `Bourse.Spec` and never calls this module. This
  repository carries a slice rather than the whole set: the supported venues plus
  the few reference-only venues the test suite uses as counter-examples. The pins
  still name the upstream revision the slice was taken from, so its provenance
  stays verifiable; the complete set lives in the authoring workbench.

  The slice's files are excluded from the Hex package.
  """

  alias Bourse.JsonDocument

  @reference_root "priv/specs/json"
  @valid_id_pattern ~r/^[a-z0-9_]+$/

  @doc "Returns the reference-corpus manifest path."
  @spec manifest_path() :: String.t()
  def manifest_path, do: Path.join(reference_root(), "reference_corpus.json")

  @doc "Loads and validates the reference-corpus manifest."
  @spec load_manifest!() :: map()
  def load_manifest! do
    manifest = JsonDocument.decode_file!(manifest_path())

    case manifest do
      %{
        "kind" => "ccxt_reference_corpus",
        "schema_version" => 1,
        "exchange_count" => count,
        "exchanges" => exchanges,
        "pins" => pins
      }
      when is_integer(count) and is_list(exchanges) and is_map(pins) ->
        validate_inventory!(count, exchanges)
        validate_pins!(pins)
        manifest

      _ ->
        raise "invalid CCXT reference-corpus manifest contract"
    end
  end

  @doc "Returns every version-pinned reference exchange id."
  @spec exchanges() :: [String.t()]
  def exchanges, do: load_manifest!()["exchanges"]

  @doc "Returns a reference-document path after validating its inventory membership."
  @spec spec_path(String.t()) :: String.t()
  def spec_path(exchange_id) when is_binary(exchange_id) do
    validate_id!(exchange_id)

    if exchange_id in exchanges() do
      Path.join([reference_root(), "output", "#{exchange_id}.json"])
    else
      raise ArgumentError, "unknown reference exchange: #{inspect(exchange_id)}"
    end
  end

  @doc "Validates the manifest, its pins, and every reference JSON document."
  @spec validate_all_documents!() :: :ok
  def validate_all_documents! do
    load_manifest!()
    Enum.each(exchanges(), &(&1 |> spec_path() |> JsonDocument.decode_file!()))
    :ok
  end

  defp validate_inventory!(count, exchanges) do
    exchange_count = length(exchanges)

    cond do
      count != exchange_count ->
        raise "reference-corpus exchange_count #{count} does not match #{exchange_count} exchanges"

      exchanges != Enum.sort(Enum.uniq(exchanges)) ->
        raise "reference-corpus exchanges must be unique and sorted"

      Enum.any?(exchanges, &(not is_binary(&1) or not Regex.match?(@valid_id_pattern, &1))) ->
        raise "reference-corpus manifest contains an invalid exchange id"

      true ->
        :ok
    end
  end

  defp validate_pins!(pins) do
    Enum.each(["source", "static_fixtures"], &validate_pin!(pins, &1))
  end

  defp validate_pin!(pins, key) do
    case Map.fetch(pins, key) do
      {:ok, %{"path" => relative_path, "sha256" => expected_sha256}}
      when is_binary(relative_path) and relative_path != "" and
             is_binary(expected_sha256) and byte_size(expected_sha256) == 64 ->
        verify_pin_sha256!(key, relative_path, expected_sha256)

      _ ->
        raise "reference-corpus manifest missing pin #{key}"
    end
  end

  defp verify_pin_sha256!(key, relative_path, expected_sha256) do
    path = Path.join(reference_root(), relative_path)
    contents = File.read!(path)
    actual_sha256 = :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)

    if actual_sha256 != expected_sha256 do
      raise "reference-corpus pin #{key} SHA-256 mismatch: #{path}"
    end
  end

  defp validate_id!(exchange_id) do
    if !Regex.match?(@valid_id_pattern, exchange_id) do
      raise ArgumentError, "invalid exchange ID: #{inspect(exchange_id)}"
    end
  end

  defp reference_root do
    case :code.priv_dir(:bourse) do
      {:error, :bad_name} -> @reference_root
      priv_dir -> Path.join(to_string(priv_dir), "specs/json")
    end
  end
end
