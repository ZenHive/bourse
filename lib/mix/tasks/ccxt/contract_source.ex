defmodule Mix.Tasks.Ccxt.ContractSource do
  @moduledoc """
  Normalizes mechanical operation facts from pinned provider artifacts.

  The normalizer preserves absent source detail as an explicit unknown fact. It
  does not infer provider semantics from names, examples, or neighboring fields.
  """

  alias Mix.Tasks.Ccxt.AuthorityCorpus

  @http_methods ~w(get post put patch delete head options trace)
  @surface_digest_kinds ~w(openapi-json openapi-yaml asyncapi-json)
  @inventory_json_kinds ~w(openapi-json asyncapi-json)

  @typedoc "A source fact whose absence is explicit."
  @type fact :: %{required(String.t()) => term()}

  @typedoc "Normalized operation facts from one provider artifact."
  @type result :: %{
          operations: [map()],
          limitations: [String.t()],
          metrics: %{optional(String.t()) => non_neg_integer()}
        }

  @doc "Parses the mechanical facts supported by an authority artifact."
  @spec parse!(map(), binary()) :: result()
  def parse!(%{"kind" => kind}, contents) when kind in ~w(openapi-json openapi-yaml) do
    document = decode_openapi!(kind, contents)
    operations = normalize_openapi(document)

    result(
      operations,
      openapi_limitations(operations),
      %{
        "operation_count" => length(operations),
        "path_count" => map_size(document["paths"] || %{}),
        "websocket_only_operation_count" => Enum.count(operations, &("websocket_only" in &1["qualifiers"])),
        "unknown_authentication_count" => Enum.count(operations, &unknown?(&1["authentication"]))
      }
    )
  end

  def parse!(%{"kind" => "postman-collection"}, contents) do
    document = Jason.decode!(contents)
    operations = normalize_postman(document)

    result(
      operations,
      [
        "Postman request collections are untyped and cannot establish response schemas or completeness.",
        "Postman examples are documentation samples, not paired live observations or safety evidence."
      ],
      %{"operation_count" => length(operations)}
    )
  end

  def parse!(%{"kind" => "asyncapi-json"}, contents) do
    document = Jason.decode!(contents)
    operations = normalize_asyncapi(document)

    result(
      operations,
      asyncapi_limitations(operations),
      %{
        "channel_count" => map_size(document["channels"] || %{}),
        "operation_count" => length(operations),
        "message_reference_inversion_count" =>
          Enum.count(operations, &("message_reference_direction_inversion" in &1["qualifiers"]))
      }
    )
  end

  def parse!(artifact, _contents) do
    level = get_in(artifact, ["expressiveness", "level"]) || "unknown"

    result(
      [],
      [
        "#{level} source #{artifact["id"] || "unknown"} has no mechanically normalized operation inventory."
      ],
      %{"operation_count" => 0}
    )
  end

  @doc """
  Builds a structural surface digest from pinned artifact bytes.

  The digest retains named channel, path, and operation keys plus per-entity
  hashes. It is what a later drift review diffs when the previous full document
  is no longer fetchable. Untyped and prose artifacts produce empty key sets.
  """
  @spec surface_digest(map(), binary()) :: map()
  def surface_digest(artifact, contents) when is_map(artifact) and is_binary(contents) do
    parsed = parse!(artifact, contents)
    document = inventory_document(artifact, contents)
    operations = retained_operations(artifact, parsed.operations)
    channel_keys = map_keys(document["channels"])
    path_keys = document["paths"] |> map_keys() |> Enum.map(&normalize_path/1) |> Enum.sort()
    operation_keys = operations |> Enum.map(& &1["key"]) |> Enum.sort()

    %{
      "schema_version" => 1,
      "report_type" => "authority_surface_digest",
      "artifact_id" => artifact["id"],
      "kind" => artifact["kind"],
      "source" => %{
        "sha256" => AuthorityCorpus.sha256(contents),
        "bytes" => byte_size(contents)
      },
      "key_sets" => %{
        "channel_keys" => channel_keys,
        "path_keys" => path_keys,
        "operation_keys" => operation_keys
      },
      "key_set_sha256" => %{
        "channel_keys" => hash_key_set(channel_keys),
        "path_keys" => hash_key_set(path_keys),
        "operation_keys" => hash_key_set(operation_keys)
      },
      "entities" =>
        Enum.sort_by(
          channel_entities(document) ++ path_entities(document) ++ operation_entities(operations),
          &{&1["kind"], &1["key"]}
        ),
      "metrics" => parsed.metrics,
      "limitations" => digest_limitations(artifact, parsed, channel_keys, path_keys, operation_keys)
    }
  end

  @doc "Hashes a key set the way committed drift reports hash channel keys."
  @spec hash_key_set([String.t()]) :: String.t() | nil
  def hash_key_set([]), do: nil

  def hash_key_set(keys) when is_list(keys) do
    keys |> Enum.sort() |> Enum.join("\n") |> AuthorityCorpus.sha256()
  end

  @doc "Returns an explicit known source fact."
  @spec known(term()) :: fact()
  def known(value), do: %{"status" => "known", "value" => value}

  @doc "Returns an explicit unknown source fact."
  @spec unknown() :: fact()
  def unknown, do: %{"status" => "unknown"}

  defp decode_openapi!("openapi-json", contents), do: Jason.decode!(contents)
  defp decode_openapi!("openapi-yaml", contents), do: YamlElixir.read_from_string!(contents)

  defp normalize_openapi(document) do
    document
    |> Map.get("paths", %{})
    |> Enum.flat_map(fn {path, path_item} -> openapi_path_operations(document, path, path_item) end)
    |> Enum.sort_by(& &1["key"])
  end

  defp openapi_path_operations(document, path, path_item) do
    path_parameters = Map.get(path_item, "parameters")

    path_item
    |> Enum.filter(fn {method, operation} -> method in @http_methods and is_map(operation) end)
    |> Enum.flat_map(fn {method, operation} ->
      document
      |> server_base_paths(path_item, operation)
      |> Enum.map(fn base_path ->
        openapi_operation(document, method, join_path(base_path, path), path_parameters, operation)
      end)
    end)
  end

  defp openapi_operation(document, method, path, path_parameters, operation) do
    parameters = openapi_parameters(document, path_parameters, operation)
    response_schemas = openapi_response_schemas(document, operation)
    examples = openapi_examples(document, operation, parameters, response_schemas)
    qualifiers = websocket_only_qualifier(operation)

    %{
      "key" => operation_key(method, path),
      "transport" => "rest",
      "path" => path,
      "channel" => nil,
      "method" => String.upcase(method),
      "authentication" => openapi_authentication(document, operation),
      "parameters" => parameters,
      "response_schemas" => response_schemas,
      "message_schemas" => unknown(),
      "examples" => examples,
      "message_references" => unknown(),
      "qualifiers" => qualifiers
    }
  end

  defp server_base_paths(document, path_item, operation) do
    servers = operation["servers"] || path_item["servers"] || document["servers"]

    cond do
      is_list(servers) and servers != [] ->
        servers
        |> Enum.map(&server_path/1)
        |> Enum.uniq()
        |> Enum.sort()

      is_binary(document["basePath"]) ->
        [normalize_path(document["basePath"])]

      true ->
        [""]
    end
  end

  defp server_path(%{"url" => url}) when is_binary(url) do
    case URI.parse(url).path do
      nil -> ""
      path -> normalize_path(path)
    end
  end

  defp server_path(_server), do: ""

  defp openapi_authentication(document, operation) do
    cond do
      Map.has_key?(operation, "security") -> normalize_security(operation["security"])
      Map.has_key?(document, "security") -> normalize_security(document["security"])
      true -> unknown()
    end
  end

  defp normalize_security([]), do: known(%{"required" => false, "schemes" => []})

  defp normalize_security(security) when is_list(security) do
    schemes = security |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()
    known(%{"required" => true, "schemes" => schemes})
  end

  defp normalize_security(_security), do: unknown()

  defp openapi_parameters(document, path_parameters, operation) do
    operation_parameters = Map.get(operation, "parameters")
    request_body? = Map.has_key?(operation, "requestBody")

    if is_list(path_parameters) or is_list(operation_parameters) or request_body? do
      values =
        List.wrap(path_parameters) ++
          List.wrap(operation_parameters) ++ openapi_request_body_parameter(document, operation)

      values
      |> Enum.map(&normalize_openapi_parameter(document, &1))
      |> Enum.sort_by(fn parameter -> {parameter["location"], parameter["name"]} end)
      |> known()
    else
      unknown()
    end
  end

  defp openapi_request_body_parameter(document, %{"requestBody" => request_body}) do
    request_body = resolve_local_ref(document, request_body)
    schemas = content_schemas(request_body["content"])

    parameter =
      %{"name" => "requestBody", "in" => "body"}
      |> maybe_put("required", request_body)
      |> maybe_put_schema(schemas)

    [parameter]
  end

  defp openapi_request_body_parameter(_document, _operation), do: []

  defp normalize_openapi_parameter(document, parameter) do
    source_ref = parameter["$ref"]
    parameter = resolve_local_ref(document, parameter)
    schema = parameter["schema"]

    %{
      "name" => parameter["name"],
      "location" => parameter["in"],
      "required" => optional_fact(parameter, "required"),
      "type" => parameter_type_fact(parameter, schema),
      "schema" => optional_fact(parameter, "schema"),
      "example" => parameter_example_fact(parameter),
      "source_ref" => source_ref
    }
  end

  defp parameter_type_fact(parameter, schema) do
    cond do
      is_map(schema) and Map.has_key?(schema, "type") -> known(schema["type"])
      Map.has_key?(parameter, "type") -> known(parameter["type"])
      true -> unknown()
    end
  end

  defp parameter_example_fact(parameter) do
    cond do
      Map.has_key?(parameter, "example") ->
        known(parameter["example"])

      is_map(parameter["schema"]) and Map.has_key?(parameter["schema"], "example") ->
        known(parameter["schema"]["example"])

      true ->
        unknown()
    end
  end

  defp openapi_response_schemas(document, operation) do
    if is_map(operation["responses"]) do
      schemas =
        operation["responses"]
        |> Enum.flat_map(fn {status, response} ->
          response = resolve_local_ref(document, response)

          response
          |> response_schema_values()
          |> Enum.map(&Map.put(&1, "status", status))
        end)
        |> Enum.sort_by(fn schema -> {schema["status"], schema["content_type"] || ""} end)

      if schemas == [], do: unknown(), else: known(schemas)
    else
      unknown()
    end
  end

  defp response_schema_values(response) do
    cond do
      is_map(response["content"]) -> content_schemas(response["content"])
      Map.has_key?(response, "schema") -> [%{"content_type" => nil, "schema" => response["schema"]}]
      true -> []
    end
  end

  defp content_schemas(content) when is_map(content) do
    content
    |> Enum.flat_map(fn {content_type, media} ->
      if Map.has_key?(media, "schema") do
        [%{"content_type" => content_type, "schema" => media["schema"]}]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1["content_type"])
  end

  defp content_schemas(_content), do: []

  defp openapi_examples(document, operation, parameters, response_schemas) do
    values =
      parameter_examples(parameters) ++
        request_body_examples(document, operation) ++ response_examples(document, operation, response_schemas)

    if values == [], do: unknown(), else: known(values)
  end

  defp parameter_examples(%{"status" => "known", "value" => parameters}) do
    Enum.flat_map(parameters, fn parameter ->
      case parameter["example"] do
        %{"status" => "known", "value" => value} ->
          [%{"location" => "parameter", "name" => parameter["name"], "value" => value}]

        _unknown ->
          []
      end
    end)
  end

  defp parameter_examples(_parameters), do: []

  defp request_body_examples(document, %{"requestBody" => request_body}) do
    document
    |> resolve_local_ref(request_body)
    |> Map.get("content")
    |> media_examples("request")
  end

  defp request_body_examples(_document, _operation), do: []

  defp response_examples(document, operation, %{"status" => "known"}) do
    Enum.flat_map(operation["responses"], fn {status, response} ->
      document
      |> resolve_local_ref(response)
      |> Map.get("content")
      |> media_examples("response", status)
    end)
  end

  defp response_examples(_document, _operation, _response_schemas), do: []

  defp media_examples(content, location, status \\ nil)

  defp media_examples(content, location, status) when is_map(content) do
    Enum.flat_map(content, fn {content_type, media} ->
      media
      |> media_example_values()
      |> Enum.map(&normalize_media_example(&1, location, status, content_type))
    end)
  end

  defp media_examples(_content, _location, _status), do: []

  defp media_example_values(media) do
    direct = if Map.has_key?(media, "example"), do: [{"example", media["example"]}], else: []
    direct ++ Map.to_list(media["examples"] || %{})
  end

  defp normalize_media_example({name, example}, location, status, content_type) do
    value = if is_map(example) and Map.has_key?(example, "value"), do: example["value"], else: example

    %{
      "location" => location,
      "status" => status,
      "content_type" => content_type,
      "name" => name,
      "value" => value
    }
  end

  defp websocket_only_qualifier(operation) do
    if Enum.any?(operation["tags"] || [], &(String.downcase(&1) == "websocket only")) do
      ["websocket_only"]
    else
      []
    end
  end

  defp openapi_limitations(operations) do
    {example?, missing_auth, websocket_only} =
      Enum.reduce(operations, {false, 0, 0}, fn operation, {example?, missing_auth, websocket_only} ->
        {
          example? or known?(operation["examples"]),
          missing_auth + if(unknown?(operation["authentication"]), do: 1, else: 0),
          websocket_only + if("websocket_only" in operation["qualifiers"], do: 1, else: 0)
        }
      end)

    []
    |> maybe_add(example?, "Provider examples are documentation, not observed-reality evidence.")
    |> maybe_add(
      missing_auth > 0,
      "#{missing_auth} operations omit security metadata; authentication remains unknown."
    )
    |> maybe_add(
      websocket_only > 0,
      "#{websocket_only} operations are tagged WebSocket Only and are not executable REST coverage."
    )
  end

  defp normalize_postman(document) do
    document
    |> Map.get("item", [])
    |> postman_items(document["auth"])
    |> Enum.sort_by(& &1["key"])
  end

  defp postman_items(items, inherited_auth) do
    Enum.flat_map(items, fn item ->
      auth = if Map.has_key?(item, "auth"), do: item["auth"], else: inherited_auth

      cond do
        is_list(item["item"]) -> postman_items(item["item"], auth)
        is_map(item["request"]) -> [postman_operation(item, auth)]
        true -> []
      end
    end)
  end

  defp postman_operation(item, inherited_auth) do
    request = item["request"]
    url = request["url"] || %{}
    path = postman_path(url)
    method = String.upcase(request["method"] || "UNKNOWN")
    auth = if Map.has_key?(request, "auth"), do: request["auth"], else: inherited_auth

    %{
      "key" => "#{method} #{path}",
      "transport" => "rest",
      "path" => path,
      "channel" => nil,
      "method" => method,
      "authentication" => postman_authentication(auth),
      "parameters" => postman_parameters(url),
      "response_schemas" => unknown(),
      "message_schemas" => unknown(),
      "examples" => postman_examples(request, item["response"]),
      "message_references" => unknown(),
      "qualifiers" => []
    }
  end

  defp postman_path(%{"path" => path}) when is_list(path) do
    path
    |> Enum.map_join("/", fn
      value when is_binary(value) -> value
      %{"value" => value} -> value
      value -> to_string(value)
    end)
    |> normalize_path()
    |> normalize_colon_parameters()
  end

  defp postman_path(%{"raw" => raw}) when is_binary(raw) do
    raw
    |> String.replace(~r/\{\{[^}]+\}\}/, "http://provider.invalid")
    |> URI.parse()
    |> Map.get(:path)
    |> normalize_path()
    |> normalize_colon_parameters()
  end

  defp postman_path(_url), do: "/"

  defp normalize_colon_parameters(path), do: String.replace(path, ~r/:([A-Za-z0-9_]+)/, "{\\1}")

  defp postman_authentication(nil), do: unknown()

  defp postman_authentication(%{"type" => "noauth"}) do
    known(%{"required" => false, "schemes" => []})
  end

  defp postman_authentication(%{"type" => type}) when is_binary(type) do
    known(%{"required" => true, "schemes" => [type]})
  end

  defp postman_authentication(_auth), do: unknown()

  defp postman_parameters(url) do
    if Map.has_key?(url, "query") or Map.has_key?(url, "variable") do
      query = Enum.map(url["query"] || [], &postman_parameter(&1, "query"))
      path = Enum.map(url["variable"] || [], &postman_parameter(&1, "path"))
      known(Enum.sort_by(query ++ path, fn parameter -> {parameter["location"], parameter["name"]} end))
    else
      unknown()
    end
  end

  defp postman_parameter(parameter, location) do
    %{
      "name" => parameter["key"],
      "location" => location,
      "required" => unknown(),
      "type" => unknown(),
      "schema" => unknown(),
      "example" => optional_fact(parameter, "value"),
      "enabled" => not Map.get(parameter, "disabled", false),
      "source_ref" => nil
    }
  end

  defp postman_examples(request, responses) do
    request_examples =
      case request["body"] do
        %{"raw" => raw} when is_binary(raw) ->
          [%{"location" => "request", "value" => decode_example(raw)}]

        _body ->
          []
      end

    response_examples =
      Enum.flat_map(responses || [], fn response ->
        if is_binary(response["body"]) do
          [
            %{
              "location" => "response",
              "status" => response["code"],
              "value" => decode_example(response["body"])
            }
          ]
        else
          []
        end
      end)

    case request_examples ++ response_examples do
      [] -> unknown()
      examples -> known(examples)
    end
  end

  defp decode_example(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp normalize_asyncapi(%{"operations" => operations} = document) when is_map(operations) do
    operations
    |> Enum.map(fn {name, operation} -> asyncapi_v3_operation(document, name, operation) end)
    |> Enum.sort_by(& &1["key"])
  end

  defp normalize_asyncapi(document) do
    document
    |> Map.get("channels", %{})
    |> Enum.flat_map(fn {channel, item} -> asyncapi_v2_channel(document, channel, item) end)
    |> Enum.sort_by(& &1["key"])
  end

  defp asyncapi_v2_channel(document, channel, item) do
    Enum.flat_map(~w(publish subscribe), fn method ->
      if is_map(item[method]) do
        [asyncapi_v2_operation(document, channel, method, item[method], item)]
      else
        []
      end
    end)
  end

  defp asyncapi_v3_operation(document, name, operation) do
    channel_ref = get_in(operation, ["channel", "$ref"])
    channel = asyncapi_ref_tail(channel_ref, "#/channels/") || name
    channel_item = get_in(document, ["channels", channel]) || %{}
    method = operation["action"] || "unknown"
    message_refs = Enum.map(operation["messages"] || [], & &1["$ref"])

    asyncapi_operation(document, channel, method, operation, channel_item, message_refs)
  end

  defp asyncapi_v2_operation(document, channel, method, operation, channel_item) do
    message_refs = if get_in(operation, ["message", "$ref"]), do: [operation["message"]["$ref"]], else: []
    asyncapi_operation(document, channel, method, operation, channel_item, message_refs)
  end

  defp asyncapi_operation(document, channel, method, operation, channel_item, message_refs) do
    message_values = Enum.map(message_refs, &resolve_local_ref(document, %{"$ref" => &1}))
    qualifiers = asyncapi_reference_qualifiers(method, message_refs)

    response_schemas =
      if "message_reference_direction_inversion" in qualifiers do
        unknown()
      else
        asyncapi_response_schemas(method, message_values)
      end

    %{
      "key" => "#{method} #{channel}",
      "transport" => "websocket",
      "path" => nil,
      "channel" => channel,
      "method" => method,
      "authentication" => asyncapi_authentication(operation),
      "parameters" => asyncapi_parameters(channel_item),
      "response_schemas" => response_schemas,
      "message_schemas" => asyncapi_message_schemas(message_values),
      "examples" => asyncapi_examples(message_values),
      "message_references" => known(message_refs),
      "qualifiers" => qualifiers
    }
  end

  defp asyncapi_authentication(operation) do
    if Map.has_key?(operation, "security") do
      normalize_security(operation["security"])
    else
      unknown()
    end
  end

  defp asyncapi_parameters(channel_item) do
    if Map.has_key?(channel_item, "parameters") do
      parameters =
        channel_item["parameters"]
        |> Enum.map(fn {name, parameter} ->
          %{
            "name" => name,
            "location" => "channel",
            "required" => optional_fact(parameter, "required"),
            "type" => parameter_type_fact(parameter, parameter["schema"]),
            "schema" => optional_fact(parameter, "schema"),
            "example" => parameter_example_fact(parameter),
            "source_ref" => parameter["$ref"]
          }
        end)
        |> Enum.sort_by(& &1["name"])

      known(parameters)
    else
      unknown()
    end
  end

  defp asyncapi_response_schemas(method, messages) when method in ~w(receive subscribe) do
    schemas =
      Enum.flat_map(messages, fn message -> if Map.has_key?(message, "payload"), do: [message["payload"]], else: [] end)

    if schemas == [], do: unknown(), else: known(schemas)
  end

  defp asyncapi_response_schemas(_method, _messages), do: unknown()

  defp asyncapi_message_schemas(messages) do
    schemas =
      Enum.flat_map(messages, fn message ->
        if Map.has_key?(message, "payload"), do: [message["payload"]], else: []
      end)

    if schemas == [], do: unknown(), else: known(schemas)
  end

  defp asyncapi_examples(messages) do
    examples = Enum.flat_map(messages, &(&1["examples"] || []))
    if examples == [], do: unknown(), else: known(examples)
  end

  defp asyncapi_reference_qualifiers("send", refs) do
    if Enum.any?(refs, &String.ends_with?(&1 || "", "/subscription_message")) do
      ["message_reference_direction_inversion"]
    else
      []
    end
  end

  defp asyncapi_reference_qualifiers("receive", refs) do
    if Enum.any?(refs, &String.ends_with?(&1 || "", "/subscribe_request")) do
      ["message_reference_direction_inversion"]
    else
      []
    end
  end

  defp asyncapi_reference_qualifiers(_method, _refs), do: []

  defp asyncapi_limitations(operations) do
    {inversion_count, example?} =
      Enum.reduce(operations, {0, false}, fn operation, {inversion_count, example?} ->
        {
          inversion_count +
            if("message_reference_direction_inversion" in operation["qualifiers"], do: 1, else: 0),
          example? or known?(operation["examples"])
        }
      end)

    []
    |> maybe_add(
      inversion_count > 0,
      "#{inversion_count} send/receive operations reference the opposite message direction; references are preserved without correction."
    )
    |> maybe_add(
      example?,
      "Provider examples are documentation, not observed-reality evidence."
    )
  end

  defp asyncapi_ref_tail(ref, prefix) when is_binary(ref) do
    if String.starts_with?(ref, prefix), do: String.replace_prefix(ref, prefix, "")
  end

  defp asyncapi_ref_tail(_ref, _prefix), do: nil

  defp resolve_local_ref(document, %{"$ref" => "#/" <> pointer} = value) do
    resolved =
      pointer
      |> String.split("/")
      |> Enum.map(&json_pointer_segment/1)
      |> then(&get_in(document, &1))

    if is_map(resolved), do: Map.merge(resolved, Map.delete(value, "$ref")), else: value
  end

  defp resolve_local_ref(_document, value), do: value

  defp json_pointer_segment(segment) do
    segment
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp optional_fact(map, key) do
    if Map.has_key?(map, key), do: known(map[key]), else: unknown()
  end

  defp result(operations, limitations, metrics) do
    %{operations: operations, limitations: limitations, metrics: metrics}
  end

  defp operation_key(method, path), do: "#{String.upcase(method)} #{path}"

  defp join_path(base, path), do: normalize_path("#{base}/#{path}")

  @doc "Canonicalizes a provider or authored contract path."
  @spec normalize_path(binary() | nil) :: binary()
  def normalize_path(nil), do: "/"

  def normalize_path(path) do
    path = path |> String.replace(~r{/+}, "/") |> String.trim_trailing("/")

    cond do
      path == "" -> "/"
      String.starts_with?(path, "/") -> path
      true -> "/" <> path
    end
  end

  defp known?(%{"status" => "known"}), do: true
  defp known?(_fact), do: false
  defp unknown?(%{"status" => "unknown"}), do: true
  defp unknown?(_fact), do: false

  defp maybe_add(values, true, value), do: values ++ [value]
  defp maybe_add(values, false, _value), do: values

  defp maybe_put(target, key, source) when is_binary(key) do
    if Map.has_key?(source, key), do: Map.put(target, key, source[key]), else: target
  end

  defp maybe_put_schema(target, []), do: target
  defp maybe_put_schema(target, schemas), do: Map.put(target, "schema", schemas)

  defp inventory_document(%{"kind" => kind}, contents) when kind in @inventory_json_kinds do
    Jason.decode!(contents)
  end

  defp inventory_document(%{"kind" => "openapi-yaml"}, contents) do
    YamlElixir.read_from_string!(contents)
  end

  defp inventory_document(_artifact, _contents), do: %{}

  defp retained_operations(%{"kind" => kind}, operations) when kind in @surface_digest_kinds, do: operations

  defp retained_operations(_artifact, _operations), do: []

  defp map_keys(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()
  defp map_keys(_other), do: []

  defp channel_entities(%{"channels" => channels}) when is_map(channels) do
    Enum.map(channels, fn {key, item} -> entity("channel", key, item) end)
  end

  defp channel_entities(_document), do: []

  defp path_entities(%{"paths" => paths}) when is_map(paths) do
    Enum.map(paths, fn {key, item} -> entity("path", normalize_path(key), item) end)
  end

  defp path_entities(_document), do: []

  defp operation_entities(operations) do
    Enum.map(operations, fn operation -> entity("operation", operation["key"], operation) end)
  end

  defp entity(kind, key, value) do
    %{"kind" => kind, "key" => key, "sha256" => canonical_sha256(value)}
  end

  defp canonical_sha256(value) do
    value
    |> canonicalize()
    |> Jason.encode!()
    |> AuthorityCorpus.sha256()
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, value} -> {key, canonicalize(value)} end)
  end

  defp canonicalize(values) when is_list(values), do: Enum.map(values, &canonicalize/1)
  defp canonicalize(value), do: value

  defp digest_limitations(artifact, parsed, channel_keys, path_keys, operation_keys) do
    if channel_keys == [] and path_keys == [] and operation_keys == [] do
      parsed.limitations ++
        [
          "No named channel, path, or operation keys can be retained from #{artifact["kind"] || "unknown"}; a later drift review cannot name entity-level additions or removals."
        ]
    else
      parsed.limitations
    end
  end
end
