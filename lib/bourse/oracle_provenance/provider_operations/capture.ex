defmodule Bourse.OracleProvenance.ProviderOperations.Capture do
  @moduledoc """
  Executes explicitly reviewed raw HTTP provider-operation proofs.

  The boundary receives a Task 555 comparison report and a separately reviewed
  plan. It never discovers operations from examples and never passes responses
  through Bourse's unified parser.
  """

  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance.ProviderOperations
  alias Bourse.RecordedResponseFixtures
  alias Mix.Tasks.Ccxt.AuthorityCorpus

  @request_timeout_ms 15_000
  @http_methods %{"DELETE" => :delete, "GET" => :get, "HEAD" => :head, "PATCH" => :patch, "POST" => :post, "PUT" => :put}

  @typedoc "A raw request function used by the live boundary or a deterministic test adapter."
  @type request_fun :: (map() -> {:ok, %{status: integer(), body: binary()}} | {:error, term()})

  @doc "Captures every proof in a reviewed plan and writes a hash-registered manifest."
  @spec capture_all!(Path.t(), Path.t(), Path.t(), keyword()) :: map()
  def capture_all!(inventory_path, plan_path, output_root, opts \\ []) do
    inventory = JsonDocument.decode_file!(inventory_path)
    plan = JsonDocument.decode_file!(plan_path)
    ProviderOperations.validate_plan!(plan, inventory, opts)

    request_fun = Keyword.get(opts, :request_fun, &execute_raw_request/1)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    captures =
      for operation <- plan["operations"], proof <- operation["proofs"] do
        capture!(plan, operation, proof, request_fun, now)
      end

    output_root = Path.expand(output_root)
    File.mkdir_p!(output_root)
    recordings = Enum.map(captures, &write_capture!(output_root, &1))
    manifest = build_manifest(plan, plan_path, recordings, now.())
    manifest_path = resolve_inside_root!(output_root, "_manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")

    ProviderOperations.validate!(
      root: output_root,
      manifest_path: manifest_path,
      plan_path: plan_path,
      authority_root: Keyword.get(opts, :authority_root, "priv/authority")
    )

    manifest
  end

  @doc "Returns whether an inventory operation is explicitly eligible for this REST proof boundary."
  @spec authorize(map(), map()) :: :ok | {:error, {:refused, atom()}}
  def authorize(operation, proof) when is_map(operation) and is_map(proof) do
    review = operation["execution_review"] || %{}
    request_review = proof["request_review"] || %{}
    axes = operation["inventory_axes"] || %{}
    provider = operation["provider"] || %{}

    with :ok <- require_reviewed(review),
         :ok <- require_reviewed_seed(request_review),
         :ok <- require_public_read(review),
         :ok <- require_current_rest(axes),
         :ok <- require_safe(review) do
      require_http_rest(provider)
    end
  end

  defp require_reviewed(%{"classification" => "reviewed", "decision" => "approved"}), do: :ok
  defp require_reviewed(_review), do: refused(:unclassified)

  defp require_reviewed_seed(%{"decision" => "approved"}), do: :ok
  defp require_reviewed_seed(_review), do: refused(:unreviewed_request_seed)

  defp require_public_read(%{"exposure" => "public", "effect" => "read"}), do: :ok
  defp require_public_read(%{"exposure" => exposure}) when exposure != "public", do: refused(:private)
  defp require_public_read(%{"exposure" => "public"}), do: refused(:mutating)
  defp require_public_read(_review), do: refused(:unclassified)

  defp require_current_rest(%{"contract_scope" => "current_rest"}), do: :ok
  defp require_current_rest(_axes), do: refused(:upcoming)

  defp require_safe(%{"reachability" => "safe", "safety" => "safe"}), do: :ok
  defp require_safe(_review), do: refused(:unsafe)

  defp require_http_rest(%{"transport" => "rest", "qualifiers" => qualifiers}) do
    if "websocket_only" in qualifiers, do: refused(:websocket_only), else: :ok
  end

  defp require_http_rest(_provider), do: refused(:websocket_only)

  defp capture!(plan, operation, proof, request_fun, now) do
    raw_request = proof["request"]

    response =
      case request_fun.(raw_request) do
        {:ok, %{status: status, body: body}} when is_integer(status) and is_binary(body) ->
          %{"http_status" => status, "raw_body" => body}

        {:error, reason} ->
          raise ArgumentError, "capture #{proof["capture_id"]} transport failed: #{inspect(reason)}"

        other ->
          raise ArgumentError, "capture #{proof["capture_id"]} returned invalid transport result: #{inspect(other)}"
      end

    fixture = %{
      "schema_version" => 1,
      "capture_id" => proof["capture_id"],
      "venue" => plan["venue"],
      "operation_key" => operation["operation_key"],
      "operation_id" => operation["operation_id"],
      "provider_artifact" => plan["source_revision"],
      "captured_at" => now.() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "host" => URI.parse(raw_request["url"]).host,
      "request" => raw_request,
      "response" => response,
      "evidence_semantics" => proof["evidence_semantics"],
      "row_fields_populated" => row_fields_populated?(response["raw_body"]),
      "scrubbed" => true
    }

    scrubbed = RecordedResponseFixtures.scrub_fixture(fixture)

    case RecordedResponseFixtures.safety_violations(scrubbed) do
      [] -> scrubbed
      violations -> raise ArgumentError, "capture #{proof["capture_id"]} was not scrubbed: #{inspect(violations)}"
    end
  end

  @doc "Executes one reviewed raw request without unified response parsing."
  @spec execute_raw_request(map(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def execute_raw_request(raw_request, req_opts \\ []) do
    method = Map.fetch!(@http_methods, raw_request["method"])
    headers = Enum.map(raw_request["headers"], &{&1["name"], &1["value"]})

    request_opts = [
      method: method,
      url: raw_request["url"],
      headers: headers,
      decode_body: false,
      retry: false,
      receive_timeout: @request_timeout_ms
    ]

    request_opts =
      if is_nil(raw_request["body"]), do: request_opts, else: Keyword.put(request_opts, :body, raw_request["body"])

    Req.request(request_opts, req_opts)
  end

  defp row_fields_populated?(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"result" => result}} when is_map(result) -> map_size(result) > 0
      _other -> false
    end
  end

  defp write_capture!(output_root, fixture) do
    relative_path = Path.join(fixture["venue"], "#{fixture["capture_id"]}.json")
    path = resolve_inside_root!(output_root, relative_path)
    contents = Jason.encode!(fixture, pretty: true) <> "\n"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    %{
      "capture_id" => fixture["capture_id"],
      "operation_key" => fixture["operation_key"],
      "operation_id" => fixture["operation_id"],
      "path" => relative_path,
      "host" => fixture["host"],
      "captured_at" => fixture["captured_at"],
      "http_status" => fixture["response"]["http_status"],
      "evidence_semantics" => fixture["evidence_semantics"],
      "row_fields_populated" => fixture["row_fields_populated"],
      "bytes" => byte_size(contents),
      "sha256" => AuthorityCorpus.sha256(contents)
    }
  end

  defp build_manifest(plan, plan_path, recordings, generated_at) do
    %{
      "schema_version" => 1,
      "corpus" => "provider_operation_reality",
      "generated_at" => generated_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "plan" => plan_path,
      "source_revision" => plan["source_revision"],
      "operations" => ProviderOperations.manifest_operations(plan),
      "recordings" => recordings
    }
  end

  defp resolve_inside_root!(root, relative_path) do
    path = Path.expand(relative_path, root)
    relative = Path.relative_to(path, root)

    if Path.type(relative_path) == :relative and Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../") do
      path
    else
      raise ArgumentError, "provider-operation output resolves outside its corpus root"
    end
  end

  defp refused(reason), do: {:error, {:refused, reason}}
end
