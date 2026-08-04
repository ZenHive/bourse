defmodule Bourse.Test.Generator.RawEndpointProbe do
  @moduledoc """
  Compile-time generator for per-endpoint raw-surface integration tests (Task 83).

  Sibling of `PublicEndpointProbe` (T40, zero-arg unified methods) and
  `UnifiedMethodIntegrationProbe` (T39, unified gap-fill). Consumes each
  exchange module's `__endpoints__/0` directly, iterating the full generated
  surface (hundreds to thousands of endpoints per exchange) and emitting one
  test per endpoint that (a) the probe can legally invoke and (b) the
  configured path-param defaults allow to be fully interpolated.

  ## Usage

      defmodule Bourse.Probes.Raw.BybitPrivateTest do
        use ExUnit.Case, async: false
        use Bourse.Test.Generator.RawEndpointProbe, exchange: :bybit, auth: :private
      end

  The caller owns the `defmodule` — one module per exchange per auth class
  (`:public`, `:private`, `:public_dangerous`, `:private_dangerous`). The
  generator emits only tests matching the requested combination. For
  `:private` / `:private_dangerous`, credential availability is decided while
  the test module is generated: registered exchanges get the full per-endpoint
  tests plus a thin runtime `setup_all` backstop; exchanges without registered
  credentials get one missing-credentials flunk test and no `setup_all`.
  `:public_dangerous` modules have no gate — they cover public on-chain
  broadcasts (e.g. lighter `sendTx`) that are POST writes but require no
  credentials.

  ## Emission rules (compile time)

  For each endpoint config returned by `module.__endpoints__/0`:

    * HTTP method gate:
      - `:get` → eligible
      - `:post`/`:put`/`:delete`/`:patch` → default `:public_dangerous` or
        `:private_dangerous` (follows the endpoint's `authenticated` flag);
        `:public` / `:private` when `endpoints.transaction_classification`
        marks the endpoint `transactional: false` (read-style POST)

    * Path-param gate:
      - If the path contains `{param}` templates not covered by the
        exchange's `path_param_defaults`, skip silently (no test emitted).

    * Testnet / WS-only gate (Task 112):
      - Private probes matching `@unavailable_on_testnet` section prefixes or
        `@ws_only_methods` emit one grouped `:skip` test per prefix instead of
        calling the endpoint.

    * Needs-params gate (Task 111):
      - Public probes matching `@needs_params_prefixes` emit one grouped `:skip`
        test per prefix when query params cannot be inferred.

    * Query-param injection (Task 111):
      - `ProbeConfig.query_params_for/2` merges compile-time query params
        (e.g. Bybit `category` / `symbol` / `interval` from `SymbolResolver`).

    * Authentication gate:
      - Public → always emit (no signing, no creds required).
      - Private → emit for every owned venue.
        Credential availability is handled at module-generation time: missing
        credentials collapse to one flunk test; registered exchanges keep the
        per-endpoint tests.

    * Dangerous (write) endpoints:
      - `:private_dangerous` — authenticated mutations (most POSTs). Same
        credential gate as `:private`.
      - `:public_dangerous` — writes with `authenticated: false`. Covers
        public on-chain broadcasts (lighter `sendTx`, `sendTxBatch`) and
        kucoin-style public `bullet-public` token issuance. Always emit,
        no signing requirement, no cred gate.

  ## Tags

  Module-level: `:network` + `:raw` + `:exchange_<id>` (attached from inside
  the generator's quote so they apply to tests registered via
  `unquote_splicing/1`).

  Per test:
    * `:public` or `:private` or `:dangerous` (the `:dangerous` tag is
      emitted for both `:public_dangerous` and `:private_dangerous` classes
      so existing `--include dangerous` / `--only dangerous` filters keep
      working unchanged).

  ## Assertions

  Delegates to `Bourse.IntegrationHelper.assert_public_response/3` or
  `assert_private_response/3` with `allow_4xx: true`. Raw-endpoint tests
  treat 4xx responses as acceptable evidence that the pipeline (signing,
  URL resolution, dispatch, error decoding) works end-to-end; the exchange
  simply rejected the request semantically.

  ## Running

      # All public raw endpoints
      mix test.json --quiet --include network --only raw --only public

      # One exchange only
      mix test.json --quiet --include network --only exchange_bybit

      # Private raw endpoints (needs credentials)
      mix test.json --quiet --include network --only raw --only private

      # Include write-path probes (destructive — be careful). Covers both
      # :public_dangerous (lighter sendTx etc.) and :private_dangerous.
      mix test.json --quiet --include network --include dangerous --only raw
  """

  alias Bourse.Registry
  alias Bourse.Test.Generator.RawEndpointProbe.Config, as: ProbeConfig

  @auth_classes [:public, :private, :public_dangerous, :private_dangerous]

  defmacro __using__(opts) do
    exchange = Keyword.fetch!(opts, :exchange)
    auth = Keyword.fetch!(opts, :auth)

    if auth not in @auth_classes do
      raise ArgumentError,
            "RawEndpointProbe: auth must be one of #{inspect(@auth_classes)}, got #{inspect(auth)}"
    end

    exchange_id = to_string(exchange)
    exchange_atom = String.to_atom(exchange_id)

    private_auth? = auth in [:private, :private_dangerous]
    registered? = !private_auth? or Bourse.Testnet.registered?(exchange_atom, :default)

    {runnable, skip_groups} =
      if private_auth? and not registered? do
        {[], []}
      else
        cases_for(exchange_id, auth)
      end

    test_blocks =
      if private_auth? and not registered? do
        [build_missing_credentials_test(exchange_id, exchange_atom, auth)]
      else
        for {^exchange_id, module, endpoint, ^auth, defaults} <- runnable do
          build_test(exchange_id, module, endpoint, auth, defaults)
        end
      end

    skip_blocks = Enum.map(skip_groups, &build_skip_test(exchange_id, auth, &1))

    moduletags =
      quote do
        @moduletag :network
        @moduletag :raw
        @moduletag unquote(String.to_atom("exchange_#{exchange_id}"))
      end

    setup_gate =
      if private_auth? and registered? do
        build_setup_gate(exchange_id, exchange_atom, auth)
      end

    quote do
      unquote(moduletags)
      unquote(setup_gate)
      unquote_splicing(skip_blocks)
      unquote_splicing(test_blocks)
    end
  end

  @doc """
  Offline sanity helper — returns the compile-time selection as a flat list
  of `{exchange_id, module, endpoint, tag_class, defaults}` tuples for IEx
  inspection, without actually running the suite. Skipped endpoints are omitted.
  """
  def __collect_for_inspection__, do: __inspection_snapshot__().cases

  @doc """
  Returns grouped skip metadata as `{exchange_id, auth, group_key, label, reason, count}` tuples.
  """
  def __collect_skips_for_inspection__, do: __inspection_snapshot__().skips

  @doc """
  Builds all raw-probe inspection data while deriving each exchange context once.

  `spec_loads` makes the bounded whole-catalog load count observable to the
  regression suite.
  """
  @spec __inspection_snapshot__() :: %{
          cases: [tuple()],
          skips: [tuple()],
          spec_loads: non_neg_integer()
        }
  def __inspection_snapshot__ do
    Registry.exchanges()
    |> Enum.reduce(%{cases: [], skips: [], spec_loads: 0}, fn exchange_id, snapshot ->
      inspection = inspect_exchange(exchange_id)

      %{
        cases: [inspection.cases | snapshot.cases],
        skips: [inspection.skips | snapshot.skips],
        spec_loads: inspection.spec_loads + snapshot.spec_loads
      }
    end)
    |> then(fn snapshot ->
      %{
        snapshot
        | cases: snapshot.cases |> Enum.reverse() |> List.flatten(),
          skips: snapshot.skips |> Enum.reverse() |> List.flatten()
      }
    end)
  end

  defp inspect_exchange(exchange_id) do
    case case_context(exchange_id) do
      {:ok, context} ->
        {cases, skips} = @auth_classes |> Enum.map(&inspect_auth_class(exchange_id, context, &1)) |> Enum.unzip()
        %{cases: List.flatten(cases), skips: List.flatten(skips), spec_loads: 1}

      :error ->
        %{cases: [], skips: [], spec_loads: 0}
    end
  end

  defp inspect_auth_class(exchange_id, context, auth) do
    {runnable, skip_groups} = cases_for_context(context, auth)

    skips =
      Enum.map(skip_groups, fn {group_key, label, reason, count} ->
        {exchange_id, auth, group_key, label, reason, count}
      end)

    {runnable, skips}
  end

  # ----------------------------------------------------------------------
  # Compile-time case collection (per exchange, per auth class)
  # ----------------------------------------------------------------------

  defp cases_for(exchange_id, auth) do
    case case_context(exchange_id) do
      {:ok, context} -> cases_for_context(context, auth)
      :error -> {[], []}
    end
  end

  defp case_context(exchange_id) do
    module = Registry.module_for(exchange_id)

    with true <- is_atom(module) and module != nil,
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__endpoints__, 0) do
      {:ok,
       %{
         exchange_id: exchange_id,
         module: module,
         endpoints: module.__endpoints__(),
         pattern: fetch_signing_pattern(module),
         defaults: ProbeConfig.path_param_defaults(exchange_id),
         tx_ctx: ProbeConfig.transaction_context(exchange_id)
       }}
    else
      _ -> :error
    end
  end

  defp cases_for_context(context, auth) do
    %{exchange_id: exchange_id, module: module, endpoints: endpoints} = context

    endpoints
    |> Enum.flat_map(fn endpoint ->
      classify_endpoint(
        exchange_id,
        module,
        endpoint,
        auth,
        context.pattern,
        context.defaults,
        context.tx_ctx
      )
    end)
    |> partition_skip_groups(auth)
  end

  defp partition_skip_groups(cases, auth) do
    {skipped, runnable} =
      Enum.split_with(cases, fn {exchange_id, _, endpoint, _, _} ->
        ProbeConfig.skip_group_key(exchange_id, endpoint, auth) != nil
      end)

    skip_groups =
      skipped
      |> Enum.group_by(fn {exchange_id, _, endpoint, _, _} ->
        ProbeConfig.skip_group_key(exchange_id, endpoint, auth)
      end)
      |> Enum.map(fn {group_key, group} ->
        count = length(group)
        label = ProbeConfig.skip_label(group_key)
        reason = ProbeConfig.skip_reason(group_key, count)
        {group_key, label, reason, count}
      end)
      |> Enum.sort_by(fn {{kind, prefix}, _, _, _} -> {kind, prefix} end)

    {runnable, skip_groups}
  end

  defp fetch_signing_pattern(module) do
    if function_exported?(module, :__signing__, 0) do
      Map.get(module.__signing__(), :pattern)
    end
  end

  # ----------------------------------------------------------------------
  # Per-endpoint classification
  #
  # Returns a list (0 or 1 element) of {exchange_id, module, endpoint, tag_class, defaults}
  # tuples matching the requested auth class.
  # ----------------------------------------------------------------------

  defp classify_endpoint(exchange_id, module, endpoint, requested_auth, pattern, defaults, tx_ctx) do
    if path_resolvable?(endpoint.path, defaults) do
      tag_class = tag_class_for(endpoint, tx_ctx)

      if tag_class == requested_auth do
        emit_if_eligible(tag_class, exchange_id, module, endpoint, pattern, defaults)
      else
        []
      end
    else
      []
    end
  end

  defp tag_class_for(%{method: method} = endpoint, tx_ctx) do
    cond do
      write_method?(method) and not ProbeConfig.read_style_write?(ProbeConfig.classification_for(tx_ctx, endpoint)) ->
        if endpoint.authenticated, do: :private_dangerous, else: :public_dangerous

      endpoint.authenticated ->
        :private

      true ->
        :public
    end
  end

  defp emit_if_eligible(:public, exchange_id, module, endpoint, _pattern, defaults),
    do: [{exchange_id, module, endpoint, :public, defaults}]

  defp emit_if_eligible(:private, exchange_id, module, endpoint, _pattern, defaults),
    do: [{exchange_id, module, endpoint, :private, defaults}]

  defp emit_if_eligible(:public_dangerous, exchange_id, module, endpoint, _pattern, defaults),
    do: [{exchange_id, module, endpoint, :public_dangerous, defaults}]

  defp emit_if_eligible(:private_dangerous, exchange_id, module, endpoint, _pattern, defaults),
    do: [{exchange_id, module, endpoint, :private_dangerous, defaults}]

  defp write_method?(method), do: method in [:post, :put, :delete, :patch]

  defp path_resolvable?(path, defaults) do
    ProbeConfig.unresolved_params(path, defaults) == []
  end

  # ----------------------------------------------------------------------
  # setup_all gate (registered private/dangerous modules only)
  # ----------------------------------------------------------------------

  defp build_setup_gate(exchange_id, exchange_atom, auth) do
    quote do
      setup_all do
        exchange_atom = unquote(exchange_atom)
        exchange_id = unquote(exchange_id)

        passphrase? =
          case Bourse.Exchange.new(exchange_atom) do
            {:ok, ex} -> ex.required_credentials["password"] == true
            _ -> false
          end

        if !Bourse.Testnet.registered?(exchange_atom, :default) do
          raise Bourse.IntegrationHelper.missing_credentials_message(exchange_atom, :default, passphrase: passphrase?)
        end

        try do
          _ = Bourse.Exchange.new!(exchange_atom, sandbox: true)
        rescue
          err in ArgumentError ->
            msg = Exception.message(err)

            if msg =~ "no testnet data" do
              reraise """
                      #{exchange_id}: no testnet data per spec — skipping #{unquote(auth)} probes.
                        #{msg}
                      """,
                      __STACKTRACE__
            else
              reraise err, __STACKTRACE__
            end
        end

        :ok
      end
    end
  end

  # ----------------------------------------------------------------------
  # Grouped skip emission (Task 112)
  # ----------------------------------------------------------------------

  defp build_skip_test(exchange_id, auth, {_group_key, label, reason, count}) do
    test_name = "#{exchange_id} raw skip: #{label} (#{count} endpoints)"
    tags = skip_tags(auth)

    quote do
      unquote_splicing(tags)
      @tag skip: unquote(reason)
      test unquote(test_name) do
        assert true
      end
    end
  end

  defp skip_tags(:public), do: [quote(do: @tag(:public))]
  defp skip_tags(:private), do: [quote(do: @tag(:private))]
  defp skip_tags(:public_dangerous), do: [quote(do: @tag(:dangerous)), quote(do: @tag(:public))]
  defp skip_tags(:private_dangerous), do: [quote(do: @tag(:dangerous)), quote(do: @tag(:private))]

  # ----------------------------------------------------------------------
  # Test emission
  # ----------------------------------------------------------------------

  defp build_missing_credentials_test(exchange_id, exchange_atom, auth) do
    tags = skip_tags(auth)
    passphrase? = passphrase_required?(exchange_atom)

    quote do
      unquote_splicing(tags)

      test "#{unquote(exchange_id)} raw #{unquote(auth)} missing testnet credentials" do
        flunk(
          Bourse.IntegrationHelper.missing_credentials_message(unquote(exchange_atom), :default,
            passphrase: unquote(passphrase?)
          )
        )
      end
    end
  end

  defp passphrase_required?(exchange_atom) do
    with module when is_atom(module) <- Registry.module_for(Atom.to_string(exchange_atom)),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__spec__, 0),
         %{} = describe <- map_get(module.__spec__(), "describe"),
         %{} = required <- map_get(describe, "requiredCredentials") do
      required["password"] == true
    else
      _ -> false
    end
  end

  defp map_get(%{} = map, key), do: Map.get(map, key)
  defp map_get(_value, _key), do: nil

  defp build_test(exchange_id, module, endpoint, tag_class, defaults) do
    method_str = endpoint.method |> Atom.to_string() |> String.upcase()

    # Scope path defaults to keys this endpoint's path references, then merge
    # compile-time query params (Task 111 — symbol/category/interval probes).
    params_map =
      defaults
      |> Map.take(ProbeConfig.referenced_params(endpoint.path))
      |> Map.merge(ProbeConfig.query_params_for(exchange_id, endpoint))

    ctx = %{
      exchange_id: exchange_id,
      id_atom: String.to_atom(exchange_id),
      module: module,
      endpoint: endpoint,
      name: endpoint.name,
      test_name: "#{exchange_id} raw #{method_str} #{endpoint.path} (#{endpoint.name})",
      escaped_params: Macro.escape(params_map)
    }

    build_test_quote(tag_class, ctx)
  end

  defp build_test_quote(:public, %{
         exchange_id: exchange_id,
         id_atom: id_atom,
         module: module,
         name: name,
         test_name: test_name,
         escaped_params: escaped_params
       }) do
    quote do
      @tag :public
      test unquote(test_name) do
        exchange =
          try do
            Bourse.Exchange.new!(unquote(id_atom))
          rescue
            err ->
              flunk("""
              #{unquote(exchange_id)}: Exchange.new! raised — not a transport failure:
                #{Exception.message(err)}
              """)
          end

        result = apply(unquote(module), unquote(name), [exchange, unquote(escaped_params), []])

        Bourse.IntegrationHelper.assert_public_response(unquote(name), result, allow_4xx: true)
      end
    end
  end

  defp build_test_quote(:private, %{
         exchange_id: exchange_id,
         id_atom: id_atom,
         module: module,
         name: name,
         test_name: test_name,
         escaped_params: escaped_params
       }) do
    quote do
      @tag :private
      test unquote(test_name) do
        creds = Bourse.IntegrationHelper.require_credentials!(unquote(id_atom))

        exchange =
          try do
            Bourse.IntegrationHelper.build_exchange(unquote(id_atom),
              credentials: creds,
              sandbox: true
            )
          rescue
            err ->
              flunk("""
              #{unquote(exchange_id)}: build_exchange raised — not a transport failure:
                #{Exception.message(err)}
              """)
          end

        result = apply(unquote(module), unquote(name), [exchange, unquote(escaped_params), []])

        Bourse.IntegrationHelper.assert_private_response(unquote(name), result,
          allow_4xx: true,
          allow_not_found: true,
          allow_invalid_order: true,
          allow_no_position: true
        )
      end
    end
  end

  defp build_test_quote(:public_dangerous, %{
         exchange_id: exchange_id,
         id_atom: id_atom,
         module: module,
         name: name,
         test_name: test_name,
         escaped_params: escaped_params
       }) do
    quote do
      @tag :dangerous
      @tag :public
      test unquote(test_name) do
        exchange =
          try do
            Bourse.Exchange.new!(unquote(id_atom))
          rescue
            err ->
              flunk("""
              #{unquote(exchange_id)}: Exchange.new! raised — not a transport failure:
                #{Exception.message(err)}
              """)
          end

        result = apply(unquote(module), unquote(name), [exchange, unquote(escaped_params), []])

        Bourse.IntegrationHelper.assert_public_response(unquote(name), result, allow_4xx: true)
      end
    end
  end

  defp build_test_quote(:private_dangerous, %{
         exchange_id: exchange_id,
         id_atom: id_atom,
         module: module,
         name: name,
         test_name: test_name,
         escaped_params: escaped_params
       }) do
    quote do
      @tag :dangerous
      @tag :private
      test unquote(test_name) do
        creds = Bourse.IntegrationHelper.require_credentials!(unquote(id_atom))

        exchange =
          try do
            Bourse.IntegrationHelper.build_exchange(unquote(id_atom),
              credentials: creds,
              sandbox: true
            )
          rescue
            err ->
              flunk("""
              #{unquote(exchange_id)}: build_exchange raised — not a transport failure:
                #{Exception.message(err)}
              """)
          end

        result = apply(unquote(module), unquote(name), [exchange, unquote(escaped_params), []])

        Bourse.IntegrationHelper.assert_private_response(unquote(name), result,
          allow_4xx: true,
          allow_not_found: true,
          allow_invalid_order: true,
          allow_no_position: true
        )
      end
    end
  end
end
