defmodule Bourse.OracleProvenance.MutationAdjudication.Lifecycle do
  @moduledoc """
  Executes reviewed reversible mutation lifecycles against a venue testnet.

  Every step passes `Bourse.OracleProvenance.MutationAdjudication.authorize/3`
  before a request is built, so an operation the register left unadjudicated,
  refused, unsafe or unreachable cannot be sent — there is no path that reaches
  the transport without an explicit per-operation reviewed decision.

  Cleanup is loud. Once the acting step has placed state, a failure anywhere
  later still runs the reviewed compensating operation, and the raised error says
  whether that compensation succeeded and which identifier is left behind if it
  did not.
  """

  alias Bourse.Credentials
  alias Bourse.JsonDocument
  alias Bourse.OracleProvenance.MutationAdjudication
  alias Bourse.OracleProvenance.MutationAdjudication.Redaction
  alias Bourse.OracleProvenance.PathGuard
  alias Bourse.OracleProvenance.ProviderOperations.Capture
  alias Bourse.RecordedResponseFixtures
  alias Bourse.Signing
  alias Mix.Tasks.Ccxt.AuthorityCorpus

  @credential_env ~w(DERIBIT_TESTNET_API_KEY DERIBIT_TESTNET_API_SECRET)
  @mutating_roles ~w(act cleanup idempotent_final_state failure_probe)
  @session_cleanup_operation_id "private/cancel_by_label"

  @typedoc "A raw request function used by the live boundary or a deterministic test adapter."
  @type request_fun :: (map() -> {:ok, %{status: integer(), body: binary()}} | {:error, term()})

  @doc """
  Runs every reviewed lifecycle and writes a hash-registered capture corpus.

  The written corpus is re-validated through `MutationAdjudication.validate!/1`
  before this returns, so a capture that cannot be replayed as evidence never
  survives the run that produced it.
  """
  @spec capture!(Path.t(), keyword()) :: map()
  def capture!(output_root, opts \\ []) do
    opts = Keyword.merge(MutationAdjudication.defaults(), opts)
    %{register: register, plan: plan} = MutationAdjudication.load_reviewed!(opts)

    credentials = credentials!(opts)
    request_fun = Keyword.get(opts, :request_fun, &execute!/1)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    session_label = Keyword.get(opts, :session_label, session_label(now.()))

    context = %{
      credentials: credentials,
      documented_codes: MutationAdjudication.documented_codes(opts[:errors_path]),
      now: now,
      plan: plan,
      register: register,
      redact_body_fun: Keyword.get(opts, :redact_body_fun, &redact_body!/3),
      request_fun: request_fun,
      session_label: session_label
    }

    outcomes = Enum.map(plan["lifecycles"], &run_lifecycle!(&1, context))

    output_root = Path.expand(output_root)
    File.mkdir_p!(output_root)
    recordings = outcomes |> Enum.flat_map(& &1.captures) |> Enum.map(&write_capture!(output_root, &1))
    manifest = build_manifest(register, plan, outcomes, recordings, now.(), opts)
    manifest_path = Path.join(output_root, "_manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")

    MutationAdjudication.validate!(Keyword.merge(opts, root: output_root, manifest_path: manifest_path))
    manifest
  end

  @doc "Executes one reviewed raw request without unified response parsing."
  @spec execute!(map()) :: {:ok, %{status: integer(), body: binary()}} | {:error, term()}
  def execute!(raw_request), do: Capture.execute_raw_request(raw_request)

  @doc "Returns the deterministic session label a run at `moment` uses to tag its own orders."
  @spec session_label(DateTime.t()) :: String.t()
  def session_label(moment) do
    "bourse-mutation-" <> Integer.to_string(DateTime.to_unix(moment, :millisecond))
  end

  # -- lifecycle --------------------------------------------------------------

  defp run_lifecycle!(lifecycle, context) do
    steps = lifecycle["steps"]
    cleanup = Enum.find(steps, &(&1["role"] == "cleanup"))

    initial = %{
      attempted_act?: false,
      attempted_steps: MapSet.new(),
      captures: [],
      responses: %{},
      cleaned?: false
    }

    state = run_steps!(steps, lifecycle, cleanup, context, initial)
    ensure!(state.cleaned?, "lifecycle #{lifecycle["lifecycle_id"]} never ran its reviewed cleanup")

    %{
      lifecycle_id: lifecycle["lifecycle_id"],
      operation_id: lifecycle["operation_id"],
      reversal_operation_id: lifecycle["reversal_operation_id"],
      cleanup_outcome: "completed",
      final_state: get_in(state.responses[cleanup["step_id"]], ["result", "order_state"]),
      captures: Enum.reverse(state.captures)
    }
  end

  defp run_step(step, lifecycle, cleanup, context, state) do
    request =
      protect!(step, lifecycle, cleanup, context, state, fn ->
        authorize!(step, lifecycle, context)
        build_request!(step, lifecycle, context, state)
      end)

    attempted = mark_attempted(step, state)

    {status, transport_body} =
      protect!(step, lifecycle, cleanup, context, attempted, fn -> send!(request, step, context) end)

    body =
      protect!(step, lifecycle, cleanup, context, attempted, fn -> Jason.decode!(transport_body) end)

    # Retain a parsed response before redaction and capture construction. If
    # either fails, the exact order id remains available to compensation.
    responded = %{attempted | responses: Map.put(attempted.responses, step["step_id"], body)}

    {scrubbed_body, redacted} =
      protect!(step, lifecycle, cleanup, context, responded, fn ->
        context.redact_body_fun.(body, step, context)
      end)

    fixture =
      protect!(step, lifecycle, cleanup, context, responded, fn ->
        build_fixture(step, lifecycle, context, request, status, scrubbed_body, redacted)
      end)

    next = %{
      responded
      | captures: [fixture | responded.captures],
        responses: Map.put(responded.responses, step["step_id"], scrubbed_body)
    }

    errors =
      protect!(step, lifecycle, cleanup, context, next, fn ->
        observation_errors!(step, status, scrubbed_body, context)
      end)

    case errors do
      [] -> {:ok, %{next | cleaned?: next.cleaned? or step["role"] == "cleanup"}}
      errors -> {:error, next, "step #{step["step_id"]} observed #{Enum.join(errors, "; ")}"}
    end
  end

  defp run_steps!([], _lifecycle, _cleanup, _context, state), do: state

  defp run_steps!([step | rest], lifecycle, cleanup, context, state) do
    result = run_step(step, lifecycle, cleanup, context, state)

    next =
      case result do
        {:ok, advanced} ->
          advanced

        {:error, advanced, message} ->
          compensate!(:error, %ArgumentError{message: message}, [], step, lifecycle, cleanup, context, advanced)
      end

    run_steps!(rest, lifecycle, cleanup, context, next)
  end

  defp authorize!(step, lifecycle, context) do
    case MutationAdjudication.authorize(context.register, lifecycle, step) do
      :ok -> :ok
      {:error, {:refused, reason}} -> raise ArgumentError, "step #{step["step_id"]} refused before dispatch: #{reason}"
    end
  end

  defp mark_attempted(%{"role" => role, "step_id" => step_id}, state) when role in @mutating_roles do
    %{
      state
      | attempted_act?: state.attempted_act? or role == "act",
        attempted_steps: MapSet.put(state.attempted_steps, step_id)
    }
  end

  defp mark_attempted(_step, state), do: state

  # `catch` rather than `rescue`: compensation must be total. A transport that
  # exits on timeout, or a throw, leaves the same live order behind as a raised
  # exception does, and a handler that only caught exceptions would skip the
  # compensating cancel exactly when the failure was least expected.
  defp protect!(step, lifecycle, cleanup, context, state, fun) do
    fun.()
  catch
    kind, reason -> compensate!(kind, reason, __STACKTRACE__, step, lifecycle, cleanup, context, state)
  end

  # A failure between the acting step and its cleanup would otherwise leave a
  # live order on the account, so the reviewed compensating operation is retried
  # here and the raised error states whether that retry succeeded.
  defp compensate!(kind, reason, stacktrace, step, lifecycle, cleanup, context, state) do
    note =
      cond do
        own_compensator_attempted?(step, state) ->
          compensate_now(lifecycle, own_compensator(step), context, state)

        state.attempted_act? and not state.cleaned? ->
          compensate_now(lifecycle, cleanup, context, state)

        state.cleaned? ->
          "No compensating call was needed: the reviewed cleanup had already completed."

        true ->
          "No compensating call was needed: the acting request had not been sent."
      end

    reraise ArgumentError,
            IO.iodata_to_binary([
              "lifecycle ",
              lifecycle["lifecycle_id"],
              " failed: ",
              Exception.format_banner(kind, reason, stacktrace),
              ". ",
              note
            ]),
            stacktrace
  end

  defp compensate_now(lifecycle, cleanup, context, state) do
    compensation = compensation_step(cleanup, state)

    outcome =
      try do
        authorize!(compensation, lifecycle, context)
        request = build_request!(compensation, lifecycle, context, state)
        context.request_fun.(request)
      catch
        kind, reason -> {:uncallable, Exception.format_banner(kind, reason, __STACKTRACE__)}
      end

    cleanup_note(outcome, lifecycle, compensation, context)
  end

  defp compensation_step(cleanup, state) do
    if unresolved_order_id?(cleanup, state) do
      %{
        "step_id" => "#{cleanup["step_id"]}_by_label",
        "role" => "cleanup",
        "operation_id" => @session_cleanup_operation_id,
        "authenticated" => true,
        "params" => %{"label" => %{"bind" => "session_label"}}
      }
    else
      cleanup
    end
  end

  defp unresolved_order_id?(cleanup, state) do
    Enum.any?(cleanup["params"], fn
      {_key, %{"bind" => "order_id", "from_step" => from, "path" => path}} ->
        body = Map.get(state.responses, from)
        not is_map(body) or is_nil(get_in(body, path))

      _param ->
        false
    end)
  end

  defp own_compensator_attempted?(step, state) do
    is_map(step["compensator"]) and MapSet.member?(state.attempted_steps, step["step_id"])
  end

  defp own_compensator(step) do
    step["compensator"]
    |> Map.put("step_id", "#{step["step_id"]}_compensator")
    |> Map.put("role", "cleanup")
  end

  defp cleanup_note({:ok, %{status: 200, body: body}}, _lifecycle, cleanup, _context) do
    "Reviewed cleanup #{cleanup["operation_id"]} was retried and answered #{inspect(cleanup_state(body))}."
  end

  defp cleanup_note({:uncallable, banner}, lifecycle, cleanup, context) do
    IO.iodata_to_binary([
      "🚨 Reviewed cleanup ",
      cleanup["operation_id"],
      " could not even be built: ",
      banner,
      ". ",
      orphan_note(lifecycle, context)
    ])
  end

  defp cleanup_note(other, lifecycle, cleanup, context) do
    IO.iodata_to_binary([
      "🚨 Reviewed cleanup ",
      cleanup["operation_id"],
      " FAILED with ",
      inspect(other),
      ". ",
      orphan_note(lifecycle, context)
    ])
  end

  defp orphan_note(lifecycle, context) do
    IO.iodata_to_binary([
      "Live state is left on ",
      context.plan["host"],
      ": cancel the orders labelled ",
      context.session_label,
      " on ",
      lifecycle["instrument_name"],
      " by hand."
    ])
  end

  defp cleanup_state(body) do
    case Jason.decode(body) do
      {:ok, %{"result" => %{"order_state" => state}}} -> state
      {:ok, %{"result" => result}} -> result
      {:ok, %{"error" => error}} -> error
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  # -- request ----------------------------------------------------------------

  defp build_request!(step, lifecycle, context, state) do
    params = Map.new(step["params"], fn {key, value} -> {key, bind!(value, step, lifecycle, context, state)} end)

    query = params |> Enum.sort() |> URI.encode_query()
    path = "/api/v2/#{step["operation_id"]}?#{query}"
    headers = [%{"name" => "accept", "value" => "application/json"} | auth_headers(step, path, context)]

    %{"method" => "GET", "url" => context.plan["base_url"] <> path, "headers" => headers, "body" => nil}
  end

  # The query is already interpolated into `path` because the reviewed request is
  # captured verbatim, so the signer is handed no separate params to re-encode.
  defp auth_headers(%{"authenticated" => true}, path, context) do
    request = %Signing.Request{method: :get, path: path, params: %{}, body: nil}
    signed = Signing.Deribit.sign(request, context.credentials, %{})
    Enum.map(signed.headers, fn {name, value} -> %{"name" => String.downcase(name), "value" => value} end)
  end

  defp auth_headers(_step, _path, _context), do: []

  defp bind!(value, _step, _lifecycle, _context, _state) when is_binary(value), do: value

  defp bind!(%{"bind" => "session_label"}, _step, _lifecycle, context, _state), do: context.session_label

  defp bind!(%{"bind" => "order_id"} = binding, step, _lifecycle, _context, state) do
    binding |> resolve!(step, state) |> to_string()
  end

  defp bind!(%{"bind" => "unfillable_bid"} = binding, step, _lifecycle, _context, state) do
    binding |> unfillable_price(step, state) |> format_price()
  end

  # A price offset by half a tick is off-tick by construction, so the provider
  # rejects it on the parameter itself instead of on price level or balance.
  defp bind!(%{"bind" => "off_tick_bid"} = binding, step, _lifecycle, _context, state) do
    tick = tick!(binding, step, state)
    format_price(unfillable_price(binding, step, state) + tick / 2)
  end

  defp bind!(value, step, _lifecycle, _context, _state) do
    raise ArgumentError, "step #{step["step_id"]} carries an unreviewed parameter binding #{inspect(value)}"
  end

  defp unfillable_price(binding, step, state) do
    tick = tick!(binding, step, state)
    bid = binding |> resolve!(step, state) |> to_number(step)
    Float.floor(bid / 2 / tick) * tick
  end

  defp tick!(binding, step, state) do
    tick =
      %{"from_step" => binding["tick_from_step"], "path" => binding["tick_path"]}
      |> resolve!(step, state)
      |> to_number(step)

    if tick > 0, do: tick, else: raise(ArgumentError, "step #{step["step_id"]} resolved a non-positive tick size")
  end

  defp resolve!(%{"from_step" => from, "path" => path}, step, state) when is_binary(from) and is_list(path) do
    body =
      Map.get(state.responses, from) ||
        raise ArgumentError, "step #{step["step_id"]} reads step #{from}, which has not run"

    get_in(body, path) ||
      raise ArgumentError, "step #{step["step_id"]} found no #{Enum.join(path, ".")} in step #{from}"
  end

  defp resolve!(binding, step, _state) do
    raise ArgumentError, "step #{step["step_id"]} carries an incomplete binding #{inspect(binding)}"
  end

  defp to_number(value, _step) when is_number(value), do: value

  defp to_number(value, step) do
    raise ArgumentError, "step #{step["step_id"]} resolved #{inspect(value)} where a number was reviewed"
  end

  defp format_price(price), do: Float.to_string(price * 1.0)

  defp send!(request, step, context) do
    case context.request_fun.(request) do
      {:ok, %{status: status, body: body}} when is_integer(status) and is_binary(body) ->
        {status, body}

      {:error, reason} ->
        raise ArgumentError, "step #{step["step_id"]} transport failed: #{inspect(reason)}"

      other ->
        raise ArgumentError, "step #{step["step_id"]} returned an invalid transport result: #{inspect(other)}"
    end
  end

  # -- capture ----------------------------------------------------------------

  # A private response body is a JSON string inside the fixture, so the corpus
  # scrubber — which masks sensitive map *keys* — never reaches it. The body is
  # therefore decoded, scrubbed and re-encoded here, and the paths that were
  # masked are recorded so the redaction stays inspectable.
  defp redact_body!(body, step, context) do
    violations = RecordedResponseFixtures.safety_violations(body)
    scrubbed = RecordedResponseFixtures.scrub_fixture(body, context.credentials)

    case RecordedResponseFixtures.safety_violations(scrubbed) do
      [] -> {scrubbed, violations}
      remaining -> raise ArgumentError, "step #{step["step_id"]} body still exposes #{Enum.join(remaining, ", ")}"
    end
  end

  defp build_fixture(step, lifecycle, context, request, status, body, redacted) do
    fixture = %{
      "schema_version" => 1,
      "capture_id" => step["step_id"],
      "venue" => context.register["venue"],
      "lifecycle_id" => lifecycle["lifecycle_id"],
      "step_id" => step["step_id"],
      "role" => step["role"],
      "operation_key" => "GET /api/v2/#{step["operation_id"]}",
      "operation_id" => step["operation_id"],
      "source_binding" => context.register["source_binding"],
      "captured_at" => context.now.() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "host" => URI.parse(request["url"]).host,
      "request" => Redaction.redact_request(request),
      "response" => %{
        "http_status" => status,
        "raw_body" => Jason.encode!(body),
        "redacted_body_paths" => redacted
      },
      "evidence_semantics" => step["evidence_semantics"],
      "row_fields_populated" => MutationAdjudication.row_fields_populated?(body),
      "scrubbed" => true
    }

    case Redaction.violations(fixture) do
      [] -> fixture
      paths -> raise ArgumentError, "capture #{step["step_id"]} still carries credentials at #{Enum.join(paths, ", ")}"
    end
  end

  defp observation_errors!(step, status, body, context) do
    expected = step["expected"]

    status_errors =
      if status == expected["http_status"],
        do: [],
        else: ["HTTP #{status} where the review expects #{expected["http_status"]}"]

    status_errors ++ MutationAdjudication.observation_errors(expected, body, context.documented_codes)
  end

  defp write_capture!(output_root, fixture) do
    relative_path = Path.join(fixture["venue"], "#{fixture["capture_id"]}.json")
    path = PathGuard.resolve_inside_root!(output_root, relative_path, "registered mutation capture")
    contents = Jason.encode!(fixture, pretty: true) <> "\n"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    %{
      "capture_id" => fixture["capture_id"],
      "lifecycle_id" => fixture["lifecycle_id"],
      "step_id" => fixture["step_id"],
      "role" => fixture["role"],
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

  defp build_manifest(register, plan, outcomes, recordings, generated_at, opts) do
    captures =
      outcomes
      |> Enum.flat_map(& &1.captures)
      |> Enum.filter(&(&1["evidence_semantics"] == "row_fields" and &1["row_fields_populated"]))
      |> Enum.group_by(& &1["operation_id"], & &1["capture_id"])

    authored = JsonDocument.decode_file!(Path.join(opts[:spec_root], "#{register["venue"]}.json"))

    %{
      "schema_version" => 1,
      "corpus" => "provider_mutation_reality",
      "venue" => register["venue"],
      "generated_at" => generated_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "adjudication" => opts[:register_path],
      "plan" => opts[:plan_path],
      "environment" => plan["environment"],
      "host" => plan["host"],
      "source_binding" => register["source_binding"],
      "lifecycles" =>
        Enum.map(outcomes, fn outcome ->
          %{
            "lifecycle_id" => outcome.lifecycle_id,
            "operation_id" => outcome.operation_id,
            "reversal_operation_id" => outcome.reversal_operation_id,
            "cleanup_outcome" => outcome.cleanup_outcome,
            "final_state" => outcome.final_state
          }
        end),
      "operations" => MutationAdjudication.manifest_operations(register, captures, authored),
      "recordings" => recordings
    }
  end

  # -- credentials ------------------------------------------------------------

  defp credentials!(opts) do
    case Keyword.get(opts, :credentials) do
      %Credentials{} = credentials -> credentials
      nil -> credentials_from_env!()
    end
  end

  defp credentials_from_env! do
    missing = Enum.reject(@credential_env, &(System.get_env(&1) not in [nil, ""]))

    if missing != [] do
      raise ArgumentError,
            IO.iodata_to_binary([
              "deribit testnet credentials are missing: ",
              Enum.join(missing, ", "),
              ". Create a key at https://test.deribit.com/account/BTC/api and export it:\n",
              Enum.map_join(missing, "\n", &"  export #{&1}=...")
            ])
    end

    Credentials.new!(
      api_key: System.fetch_env!("DERIBIT_TESTNET_API_KEY"),
      secret: System.fetch_env!("DERIBIT_TESTNET_API_SECRET")
    )
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)
end
