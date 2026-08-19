defmodule Bourse.Spec.Promotion do
  @moduledoc """
  Builds and gates complete owned-spec candidates from pinned CCXT references.

  Preparation copies mechanical transport and metadata bulk, but resets every
  interpretive slot and unified capability to an explicit candidate state. A
  successful gate returns a complete owned document; it does not add the venue
  to `Bourse.Spec`, the registry, or the compiled exchange set.
  """

  alias Bourse.Spec.Promotion.Evidence
  alias Bourse.Spec.Promotion.Gap
  alias Bourse.Spec.Schema

  @candidate_markers %{"authored" => false, "frozen" => false, "hand_owned" => false}
  @owned_markers %{"authored" => true, "frozen" => true, "hand_owned" => true}
  @unresolved_map %{
    "promotion_status" => "unresolved",
    "reason" => "requires provider-owned authoring"
  }
  @unresolved_list ["__promotion_unresolved__"]

  @interpretive_slots [
    {"emulated_methods", ~w(emulated_methods), @unresolved_list},
    {"auth.authenticated_sections", ~w(auth authenticated_sections), @unresolved_list},
    {"auth.signing_config", ~w(auth signing_config), @unresolved_map},
    {"auth.signing_pattern", ~w(auth signing_pattern), "__promotion_unresolved__"},
    {"auth.sign_recipe", ~w(auth sign_recipe), @unresolved_map},
    {"endpoints.descriptors", ~w(endpoints descriptors), @unresolved_map},
    {"endpoints.handlers", ~w(endpoints handlers), @unresolved_map},
    {"endpoints.request", ~w(endpoints request), @unresolved_map},
    {"endpoints.transaction_classification", ~w(endpoints transaction_classification), @unresolved_map},
    {"normalization.field_maps", ~w(normalization field_maps), @unresolved_map},
    {"normalization.response_envelopes", ~w(normalization response_envelopes), @unresolved_map},
    {"markets.patterns", ~w(markets patterns), @unresolved_map},
    {"markets.symbol_patterns", ~w(markets symbol_patterns), @unresolved_map},
    {"errors", ~w(errors), @unresolved_map},
    {"websocket.auth", ~w(websocket auth), @unresolved_map},
    {"websocket.dispatch", ~w(websocket dispatch), @unresolved_map},
    {"websocket.heartbeat", ~w(websocket heartbeat), @unresolved_map},
    {"websocket.ohlcv_semantics", ~w(websocket ohlcv_semantics), @unresolved_map},
    {"websocket.orderbook_semantics", ~w(websocket orderbook_semantics), @unresolved_map},
    {"websocket.subscribe", ~w(websocket subscribe), @unresolved_map},
    {"websocket.trades_semantics", ~w(websocket trades_semantics), @unresolved_map}
  ]

  @top_level_reference_keys ~w(_provenance ccxt_version extracted_at oracle_provenance)
  @nested_reference_keys [
    {~w(auth), ~w(headers sign_method)},
    {~w(raw), ~w(class_info method_inventory overrides_meta)},
    {~w(endpoints), ~w(interfaces pagination)},
    {~w(normalization), ~w(parse_methods_digest)},
    {~w(markets), ~w(precision_mode symbols_index)},
    {~w(errors handle_errors), ~w(http_exceptions method throw_dispatches)}
  ]

  @typedoc "A promotion failure with a stable code and actionable message."
  @type gap :: Gap.t()

  @doc "Builds a candidate and evidence report from a decoded pinned CCXT reference."
  @spec prepare(map(), map()) :: {map(), map()}
  def prepare(reference, provenance) when is_map(reference) and is_map(provenance) do
    venue = get_in(reference, ["exchange", "id"])

    if not (is_binary(venue) and venue != "") do
      raise ArgumentError, "reference spec must contain a non-empty exchange.id"
    end

    methods = reference_methods(reference)

    candidate =
      reference
      |> strip_reference_only_data()
      |> Map.put("schema_version", Bourse.Spec.schema_version())
      |> Map.merge(@candidate_markers)
      |> remove_reference_capability_claims()
      |> reset_interpretive_slots()
      |> put_in(["capabilities", "has"], Map.new(methods, &{&1, false}))
      |> put_in(["capabilities", "mapping_complete"], Map.new(methods, &{&1, false}))
      |> put_in(["capabilities", "verification"], Map.new(methods, &{&1, "unverified"}))
      |> put_in(["capabilities", "unsupported_raw_endpoints"], %{})
      |> put_in(["endpoints", "unified"], Map.new(methods, &{&1, []}))

    report =
      Evidence.template(
        venue,
        reference_provenance(reference, provenance),
        methods,
        Enum.map(@interpretive_slots, &elem(&1, 0)),
        candidate
      )

    {candidate, report}
  end

  @doc "Reads a pinned reference file and builds its candidate and report."
  @spec prepare_file!(Path.t()) :: {map(), map()}
  def prepare_file!(reference_path) when is_binary(reference_path) do
    contents = File.read!(reference_path)
    reference = Bourse.Spec.decode_file!(reference_path)

    prepare(reference, %{
      "path" => reference_path,
      "sha256" => sha256(contents)
    })
  end

  @doc """
  Returns the promoted owned document or every promotion gap.

  Re-reads the pinned CCXT reference (from `opts[:reference]` or
  `report["reference"]["path"]`), verifies its bytes against
  `report["reference"]["sha256"]`, and re-derives the method inventory from
  that reference so candidate/report cannot silently drop methods together.
  """
  @spec promote(map(), map(), keyword()) :: {:ok, map()} | {:error, [gap()]}
  def promote(candidate, report, opts \\ []) when is_map(candidate) and is_map(report) do
    subjects = Enum.map(@interpretive_slots, &elem(&1, 0))

    case load_pinned_reference_methods(report, opts) do
      {:ok, reference_methods} ->
        owned = Map.merge(candidate, @owned_markers)

        gaps =
          candidate_gaps(owned, reference_methods) ++
            Evidence.gaps(candidate, report, reference_methods, subjects, opts)

        case gaps do
          [] -> {:ok, owned}
          gaps -> {:error, Enum.uniq(gaps)}
        end

      {:error, gaps} ->
        {:error, gaps}
    end
  end

  @doc "Encodes a candidate or report with stable pretty-printed JSON bytes."
  @spec encode!(map()) :: String.t()
  def encode!(document) when is_map(document) do
    Jason.encode!(document, pretty: true) <> "\n"
  end

  @doc "Returns a lowercase SHA-256 digest for binary content."
  @spec sha256(binary()) :: String.t()
  def sha256(contents) when is_binary(contents) do
    :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
  end

  defp reference_methods(reference) do
    capability_methods = reference |> get_in(["capabilities", "has"]) |> map_keys()
    endpoint_methods = reference |> get_in(["endpoints", "unified"]) |> map_keys()
    Enum.sort(Enum.uniq(capability_methods ++ endpoint_methods))
  end

  defp map_keys(value) when is_map(value), do: Map.keys(value)
  defp map_keys(_value), do: []

  defp load_pinned_reference_methods(report, opts) do
    pin = report["reference"]
    expected_digest = is_map(pin) && pin["sha256"]
    pinned_path = is_map(pin) && pin["path"]
    explicit_path = Keyword.get(opts, :reference)

    cond do
      not (is_binary(expected_digest) and expected_digest != "") ->
        {:error,
         [
           Gap.new(
             :reference_pin_missing,
             "report.reference.sha256 is required to re-derive the method inventory"
           )
         ]}

      path = resolve_reference_path(explicit_path, pinned_path) ->
        verify_and_inventory(path, expected_digest, opts)

      true ->
        {:error,
         [
           Gap.new(
             :reference_path_missing,
             "pinned reference path is missing; pass --reference or set report.reference.path"
           )
         ]}
    end
  end

  defp resolve_reference_path(explicit, _pinned) when is_binary(explicit) and explicit != "", do: explicit
  defp resolve_reference_path(_explicit, pinned) when is_binary(pinned) and pinned != "", do: pinned
  defp resolve_reference_path(_explicit, _pinned), do: nil

  defp verify_and_inventory(path, expected_digest, opts) do
    root = Keyword.get(opts, :root, File.cwd!())
    absolute = if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)

    case File.read(absolute) do
      {:ok, contents} -> inventory_from_verified_bytes(contents, expected_digest, absolute)
      {:error, reason} -> reference_missing_error(absolute, reason)
    end
  end

  defp inventory_from_verified_bytes(contents, expected_digest, absolute) do
    actual = sha256(contents)

    if actual == expected_digest do
      decode_reference_inventory(contents, absolute)
    else
      {:error,
       [
         Gap.new(
           :reference_digest_mismatch,
           "pinned reference sha256 mismatch for #{absolute}: expected #{expected_digest}, got #{actual}"
         )
       ]}
    end
  end

  defp decode_reference_inventory(contents, absolute) do
    case Jason.decode(contents) do
      {:ok, reference} when is_map(reference) ->
        {:ok, reference_methods(reference)}

      _other ->
        {:error,
         [
           Gap.new(
             :reference_unreadable,
             "pinned reference is not a JSON object: #{absolute}"
           )
         ]}
    end
  end

  defp reference_missing_error(absolute, reason) do
    {:error,
     [
       Gap.new(
         :reference_missing,
         "cannot read pinned reference #{absolute}: #{inspect(reason)}"
       )
     ]}
  end

  defp strip_reference_only_data(reference) do
    Enum.reduce(@nested_reference_keys, Map.drop(reference, @top_level_reference_keys), fn {path, keys}, spec ->
      update_in(spec, path, fn
        value when is_map(value) -> Map.drop(value, keys)
        value -> value
      end)
    end)
  end

  defp remove_reference_capability_claims(spec) do
    update_in(spec, ["raw", "describe"], fn
      describe when is_map(describe) ->
        Map.drop(describe, ~w(has exceptions httpExceptions commonCurrencies precisionMode))

      describe ->
        describe
    end)
  end

  defp reset_interpretive_slots(spec) do
    Enum.reduce(@interpretive_slots, spec, fn {_subject, path, value}, candidate ->
      put_in(candidate, path, value)
    end)
  end

  defp reference_provenance(reference, provenance) do
    %{
      "kind" => "ccxt",
      "source" => "pinned_reference_spec",
      "path" => Map.fetch!(provenance, "path"),
      "sha256" => Map.fetch!(provenance, "sha256"),
      "version" => reference["ccxt_version"],
      "retrieved_at" => reference["extracted_at"]
    }
  end

  defp candidate_gaps(candidate, methods) do
    schema_gaps(candidate) ++
      unresolved_slot_gaps(candidate) ++
      support_gaps(candidate, methods) ++
      deterministic_gaps(candidate)
  end

  defp schema_gaps(candidate) do
    venue = get_in(candidate, ["exchange", "id"]) || "unknown"

    try do
      Schema.validate!(candidate, venue)
      []
    rescue
      error in ArgumentError -> [Gap.new(:schema_invalid, Exception.message(error))]
    end
  end

  defp unresolved_slot_gaps(candidate) do
    Enum.flat_map(@interpretive_slots, fn {subject, path, _placeholder} ->
      value = get_in(candidate, path)

      if unresolved?(value) do
        [Gap.new(:interpretive_slot_unresolved, "#{subject} is unresolved", "decision:#{subject}")]
      else
        []
      end
    end)
  end

  defp unresolved?(value) when is_map(value) do
    value["promotion_status"] == "unresolved" or
      Enum.any?(value, fn {key, nested} ->
        (key == "_unresolved_reason" and not is_nil(nested)) or
          (key == "resolved_from" and nested in ["heuristic", "inferred", "defaulted"]) or
          unresolved?(nested)
      end)
  end

  defp unresolved?(value) when is_list(value), do: Enum.any?(value, &unresolved?/1)

  defp unresolved?(value) when is_binary(value) do
    value in ["__promotion_unresolved__", "__undefined", "heuristic", "inferred", "defaulted", "not_yet_derived"]
  end

  defp unresolved?(_value), do: false

  defp support_gaps(candidate, methods) do
    support = get_in(candidate, ["capabilities", "has"]) || %{}
    unified = get_in(candidate, ["endpoints", "unified"]) || %{}

    Enum.flat_map(methods, fn method ->
      case {Map.fetch(support, method), Map.fetch(unified, method)} do
        {{:ok, declaration}, {:ok, endpoints}} -> validate_support_contract(method, declaration, endpoints)
        _missing -> [support_gap(method, "must appear in both capabilities.has and endpoints.unified")]
      end
    end)
  end

  defp validate_support_contract(_method, false, []), do: []

  defp validate_support_contract(method, false, _endpoints),
    do: [support_gap(method, "is unsupported and must have no unified endpoints")]

  defp validate_support_contract(_method, true, endpoints) when is_list(endpoints) and endpoints != [], do: []

  defp validate_support_contract(_method, "emulated", endpoints) when is_list(endpoints), do: []

  defp validate_support_contract(method, true, _endpoints) do
    [support_gap(method, "is supported and must have at least one unified endpoint")]
  end

  defp validate_support_contract(method, _declaration, _endpoints) do
    [support_gap(method, "must be explicitly true, false, or emulated")]
  end

  defp support_gap(method, message) do
    Gap.new(:capability_contract_invalid, "#{method} #{message}", "capability:#{method}")
  end

  defp deterministic_gaps(candidate) do
    encoded = encode!(candidate)

    if encoded == encode!(Jason.decode!(encoded)) do
      []
    else
      [Gap.new(:nondeterministic_output, "candidate JSON is not deterministic")]
    end
  end
end
