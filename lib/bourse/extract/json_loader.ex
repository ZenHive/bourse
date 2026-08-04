defmodule Bourse.Extract.JsonLoader do
  @moduledoc """
  Generates JSON loading boilerplate with `:persistent_term` caching.

  Documents are decoded through `Bourse.JsonDocument`, so duplicate object keys
  fail loudly (file, key, object path) rather than silently keeping the first
  occurrence.
  """

  alias Bourse.JsonDocument

  @extractor_dir "priv/extractor"

  @doc """
  Decodes an extractor document after rejecting duplicate JSON object keys.

  Shared path used by generated loaders; also the entry point for tests and
  catalog validation.
  """
  @spec decode_file!(String.t()) :: map()
  def decode_file!(path) when is_binary(path) do
    JsonDocument.decode_file!(path)
  end

  @doc """
  Validates every JSON document under `priv/extractor/`.

  Hand-edited extractor documents (e.g. `ccxt_emulated_methods.json` with
  `authored_delegate` entries) are covered the moment they land — duplicate-key
  loss is a property of hand-editing, not of machine-frozen distill output.
  """
  @spec validate_all_documents!() :: :ok
  def validate_all_documents! do
    extractor_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&decode_file!/1)

    :ok
  end

  defp extractor_dir do
    case :code.priv_dir(:bourse) do
      {:error, :bad_name} -> Path.expand(@extractor_dir)
      priv_dir -> Path.join(to_string(priv_dir), "extractor")
    end
  end

  defmacro __using__(opts) do
    file = Keyword.fetch!(opts, :file)
    # Bind outside the quote so generated modules call this loader without a
    # nested-module literal Credo would flag inside the expanded body.
    loader = __MODULE__

    quote do
      @json_path (case :code.priv_dir(:bourse) do
                    {:error, :bad_name} ->
                      [__DIR__, "..", "..", "priv", "extractor", unquote(file)]
                      |> Path.join()
                      |> Path.expand()

                    priv when is_list(priv) ->
                      Path.join(List.to_string(priv), "extractor/" <> unquote(file))
                  end)

      @doc "Returns the JSON file path."
      @spec path() :: String.t()
      def path, do: @json_path

      @doc "Loads the JSON data with `:persistent_term` caching."
      @spec load() :: map()
      def load do
        case :persistent_term.get({__MODULE__, :data}, :missing) do
          :missing ->
            data = read_json!()
            :persistent_term.put({__MODULE__, :data}, data)
            data

          data ->
            data
        end
      end

      @doc "Reloads JSON from disk, bypassing cache."
      @spec reload!() :: map()
      def reload! do
        data = read_json!()
        :persistent_term.put({__MODULE__, :data}, data)
        data
      end

      @doc false
      defp read_json! do
        unquote(loader).decode_file!(@json_path)
      end
    end
  end
end
