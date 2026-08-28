defmodule Bourse.Spec.Disk do
  @moduledoc """
  Endpoint-major on-disk authored specs and facet-major in-memory reassembly.

  Each venue's `priv/venues/<venue>/authored/` directory holds identity, markets,
  errors, normalization, unified methods, and raw endpoints as separate JSON
  files. `assemble!/2` rotates that layout back into the facet-major map
  `Bourse.Spec.Schema` and the exchange generator consume.
  """

  alias Bourse.JsonDocument

  @file_names ~w(venue.json markets.json errors.json normalization.json endpoints.json raw.json)
  @venue_rotation_keys ~w(
    classification_extras
    descriptor_extras
    error_handlers
    has_endpoint_selection
    parse_helpers
    request_extras
    signing_handlers
  )

  @doc "JSON filenames that make up one authored venue document."
  @spec file_names() :: [String.t()]
  def file_names, do: @file_names

  @doc "Absolute directory of one venue's authored split files."
  @spec authored_dir(String.t(), String.t()) :: String.t()
  def authored_dir(spec_root, exchange_id) when is_binary(spec_root) and is_binary(exchange_id) do
    Path.join([spec_root, exchange_id, "authored"])
  end

  @doc "Default shared-descriptor root under a spec root."
  @spec shared_root(String.t()) :: String.t()
  def shared_root(spec_root) when is_binary(spec_root) do
    Path.join([spec_root, "_shared"])
  end

  @doc """
  All JSON files that must trigger recompilation for a venue, including shared
  descriptor files referenced by `$ref`.
  """
  @spec source_files(String.t(), String.t()) :: [String.t()]
  def source_files(spec_root, exchange_id) when is_binary(spec_root) and is_binary(exchange_id) do
    dir = authored_dir(spec_root, exchange_id)

    local =
      Enum.map(@file_names, &Path.join(dir, &1))

    shared =
      dir
      |> Path.join("endpoints.json")
      |> referenced_shared_files(spec_root)

    Enum.uniq(local ++ shared)
  end

  @doc "Assembles a facet-major spec map from an authored directory."
  @spec assemble!(String.t(), keyword()) :: map()
  def assemble!(authored_dir, opts \\ []) when is_binary(authored_dir) do
    spec_root = Keyword.get_lazy(opts, :spec_root, fn -> Path.expand("../..", authored_dir) end)
    files = Map.new(@file_names, fn name -> {name, JsonDocument.decode_file!(Path.join(authored_dir, name))} end)
    assemble_maps(files, spec_root)
  end

  @doc "Assembles a facet-major spec from already-decoded split maps."
  @spec assemble_maps(
          %{
            required(String.t()) => map() | list()
          },
          String.t()
        ) :: map()
  def assemble_maps(files, spec_root) when is_map(files) and is_binary(spec_root) do
    venue = Map.fetch!(files, "venue.json")
    endpoints = Map.fetch!(files, "endpoints.json")
    raw = Map.fetch!(files, "raw.json")

    methods = collect_methods(endpoints, venue, spec_root)
    unified = methods.unified
    descriptors = methods.descriptors
    defaults = methods.defaults
    selection = methods.selection
    parse = methods.parse
    classification = methods.classification
    has = methods.has
    mapping_complete = methods.mapping_complete
    verification = methods.verification

    pec =
      Enum.reduce(Map.fetch!(raw, "endpoints"), %{}, fn {key, obj}, acc ->
        case obj do
          %{"rate_limit" => rate_limit} -> Map.put(acc, key, rate_limit)
          _ -> acc
        end
      end)

    request =
      build_request(defaults, selection, Map.fetch!(raw, "request_shape"), Map.get(venue, "has_endpoint_selection", true))

    describe = Map.put(Map.fetch!(raw, "describe"), "api", unflatten_api(Map.fetch!(raw, "endpoints")))

    capabilities =
      venue
      |> Map.fetch!("capabilities")
      |> Map.delete("has_extras")
      |> Map.merge(%{
        "has" => has,
        "mapping_complete" => mapping_complete,
        "verification" => verification
      })

    rate_limits =
      venue
      |> Map.fetch!("rate_limits")
      |> Map.put("per_endpoint_cost", pec)

    raw_spec =
      raw
      |> Map.drop(["endpoints", "request_shape"])
      |> Map.put("describe", describe)

    venue
    |> Map.drop(@venue_rotation_keys)
    |> Map.merge(%{
      "capabilities" => capabilities,
      "endpoints" => %{
        "descriptors" => descriptors,
        "handlers" => %{
          "error" => Map.fetch!(venue, "error_handlers"),
          "parse" => parse,
          "signing" => Map.fetch!(venue, "signing_handlers")
        },
        "request" => request,
        "transaction_classification" => classification,
        "unified" => unified
      },
      "errors" => Map.fetch!(files, "errors.json"),
      "markets" => Map.fetch!(files, "markets.json"),
      "normalization" => Map.fetch!(files, "normalization.json"),
      "rate_limits" => rate_limits,
      "raw" => raw_spec
    })
  end

  defp collect_methods(endpoints, venue, spec_root) do
    seed = %{
      unified: %{},
      descriptors: Map.get(venue, "descriptor_extras") || %{},
      defaults: Map.fetch!(venue, "request_extras"),
      selection: %{},
      parse: Map.fetch!(venue, "parse_helpers"),
      classification: Map.get(venue, "classification_extras") || %{},
      has: get_in(venue, ["capabilities", "has_extras"]) || %{},
      mapping_complete: %{},
      verification: %{}
    }

    Enum.reduce(endpoints, seed, &add_method(&1, &2, spec_root))
  end

  defp add_method({method, obj}, acc, spec_root) do
    request = obj["request"] || %{}

    acc
    |> put_field(:unified, method, Map.fetch!(obj, "unified"))
    |> maybe_put(:has, method, obj["has"], Map.has_key?(obj, "has"))
    |> put_field(:mapping_complete, method, Map.fetch!(obj, "mapping_complete"))
    |> put_field(:verification, method, Map.fetch!(obj, "verification"))
    |> Map.update!(:descriptors, &put_descriptor(&1, method, obj["descriptor"], spec_root))
    |> maybe_put(:defaults, method, request["defaults"], Map.has_key?(request, "defaults"))
    |> maybe_put(:selection, method, request["endpoint_selection"], Map.has_key?(request, "endpoint_selection"))
    |> maybe_put(:parse, method, obj["parse"], Map.has_key?(obj, "parse"))
    |> maybe_put(
      :classification,
      method,
      obj["transaction_classification"],
      Map.has_key?(obj, "transaction_classification")
    )
  end

  defp put_field(acc, bucket, method, value), do: put_in(acc, [bucket, method], value)

  defp maybe_put(acc, _bucket, _method, _value, false), do: acc
  defp maybe_put(acc, bucket, method, value, true), do: put_field(acc, bucket, method, value)

  defp put_descriptor(descriptors, _method, nil, _spec_root), do: descriptors

  defp put_descriptor(descriptors, method, %{"$ref" => ref}, spec_root) do
    Map.put(descriptors, method, resolve_ref!(ref, spec_root))
  end

  defp put_descriptor(descriptors, method, descriptor, _spec_root) do
    Map.put(descriptors, method, descriptor)
  end

  defp resolve_ref!(ref, spec_root) when is_binary(ref) do
    case String.split(ref, "#", parts: 2) do
      [family, key] ->
        path = Path.join([shared_root(spec_root), family, "descriptors.json"])
        shared = JsonDocument.decode_file!(path)

        case Map.fetch(shared, key) do
          {:ok, descriptor} -> descriptor
          :error -> raise ArgumentError, "shared descriptor #{inspect(ref)} is missing from #{path}"
        end

      _ ->
        raise ArgumentError, "invalid shared descriptor ref: #{inspect(ref)}"
    end
  end

  defp referenced_shared_files(endpoints_path, spec_root) do
    if File.exists?(endpoints_path) do
      endpoints_path
      |> JsonDocument.decode_file!()
      |> Enum.flat_map(&shared_descriptor_path(&1, spec_root))
      |> Enum.uniq()
    else
      []
    end
  end

  defp shared_descriptor_path({_method, %{"descriptor" => %{"$ref" => ref}}}, spec_root) do
    case String.split(ref, "#", parts: 2) do
      [family, _] -> [Path.join([shared_root(spec_root), family, "descriptors.json"])]
      _ -> []
    end
  end

  defp shared_descriptor_path({_method, _obj}, _spec_root), do: []

  defp build_request(defaults, selection, shape, true) do
    %{"defaults" => defaults, "endpoint_selection" => selection, "shape" => shape}
  end

  defp build_request(defaults, _selection, shape, false) do
    %{"defaults" => defaults, "shape" => shape}
  end

  defp unflatten_api(endpoints) when is_map(endpoints) do
    Enum.reduce(endpoints, %{}, fn {key, obj}, acc ->
      case obj do
        %{"api" => value} -> put_path(acc, String.split(key, "."), value)
        _ -> acc
      end
    end)
  end

  defp put_path(_acc, [], value), do: value

  defp put_path(acc, [part | rest], value) when is_map(acc) do
    child = Map.get(acc, part, %{})
    Map.put(acc, part, put_path(child, rest, value))
  end
end
