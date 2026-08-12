defmodule Bourse.RecordedResponseFixtures.RequestCongruence do
  @moduledoc """
  Validates that private response recordings can be rebuilt by the runtime request path.

  Capture-only parameter injection is an explicit, exact registry. The recording
  remains valid only while the runtime builder can emit every injected parameter.
  """

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.RecordedResponseFixtures
  alias Bourse.RecordedResponseFixtures.Capture
  alias Bourse.Unified

  @default_manifest "test/fixtures/responses/_manifest.json"
  @dummy_evm_address "0x0000000000000000000000000000000000000000"
  @dummy_evm_secret "0123456789012345678901234567890123456789012345678901234567890123"
  @dummy_lighter_secret "01234567890123456789012345678901234567890123456789012345678901230123456789012345"
  @derive_subaccount_id 1

  @doc "Validates every manifest-registered private recording carrying request params."
  @spec validate!(keyword()) :: :ok
  def validate!(opts \\ []) do
    manifest_path = Keyword.get(opts, :manifest_path, @default_manifest)
    root = Keyword.get(opts, :root, Path.dirname(manifest_path))
    manifest = JsonDocument.decode_file!(manifest_path)
    injections = Capture.param_injections()
    validate_injections!(injections)

    observed =
      Enum.reduce(manifest["recordings"], %{}, fn recording, acc ->
        validate_recording!(recording, root, injections, acc)
      end)

    ensure!(
      observed |> Map.keys() |> Enum.sort() == injections |> Map.keys() |> Enum.sort(),
      stale_registry_message(observed, injections)
    )

    :ok
  end

  @doc false
  @spec validate_case!(String.t(), atom(), map(), [map()], map() | nil) :: [String.t()]
  def validate_case!(venue, method, fixture, shapes, injection) do
    caller_params = fixture["caller_params"] || fixture["params"]
    recorded_params = fixture["params"]
    observed = changed_param_names(caller_params, recorded_params)
    expected = if injection, do: injection["params"], else: []
    exempt = if injection, do: injection["exempt_params"] || [], else: []
    label = "#{venue}.#{method}"

    ensure!(
      observed == expected,
      "#{label} has unregistered capture-only params: #{named_difference(observed, expected)}"
    )

    missing = Enum.reject(observed, &(&1 in exempt or emitted?(&1, shapes)))
    ensure!(missing == [], "#{label} runtime request builder cannot emit recorded params: #{Enum.join(missing, ", ")}")
    observed
  end

  defp validate_recording!(recording, root, injections, observed) do
    venue = recording["venue"]

    with {:ok, method} <- private_method(venue, recording["method"]),
         fixture = load_fixture!(root, recording["path"]),
         params when is_map(params) and map_size(params) > 0 <- fixture["params"] do
      injection = Map.get(injections, {venue, method})
      caller_params = fixture["caller_params"] || params
      changed = changed_param_names(caller_params, params)
      expected = if injection, do: injection["params"], else: []
      exempt = if injection, do: injection["exempt_params"] || [], else: []

      ensure!(
        changed == expected,
        "#{venue}.#{method} has unregistered capture-only params: #{named_difference(changed, expected)}"
      )

      shapes =
        if changed != [] and changed == exempt, do: [], else: request_shapes!(venue, method, caller_params, fixture)

      names = validate_case!(venue, method, fixture, shapes, injection)

      if names == [], do: observed, else: Map.put(observed, {venue, method}, injection)
    else
      :not_private -> observed
      nil -> observed
      _empty_or_non_map -> observed
    end
  end

  defp private_method(venue, method_name) do
    Enum.find_value(Capture.targets(), :not_private, fn
      {^venue, method} ->
        if Atom.to_string(method) == method_name and Capture.category(venue, method) == :private,
          do: {:ok, method}

      _target ->
        nil
    end)
  end

  defp load_fixture!(root, relative_path) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(relative_path, expanded_root)
    relative = Path.relative_to(expanded_path, expanded_root)

    ensure!(
      Path.type(relative_path) == :relative and Path.type(relative) == :relative and relative != ".." and
        not String.starts_with?(relative, "../"),
      "recorded response resolves outside its corpus root"
    )

    RecordedResponseFixtures.load_fixture!(expanded_path)
  end

  defp request_shapes!(venue, method, params, fixture) do
    exchange = Exchange.new!(venue, exchange_opts(venue))
    opts = RecordedResponseFixtures.decode_call_opts(fixture)

    case Unified.request_param_shapes(exchange, method, params, opts) do
      {:ok, shapes} -> shapes
      {:error, reason} -> raise ArgumentError, "#{venue}.#{method} request shape failed: #{inspect(reason)}"
    end
  end

  defp exchange_opts("derive") do
    [credentials: credentials("derive"), options: %{"subaccount_id" => @derive_subaccount_id}, sandbox: true]
  end

  defp exchange_opts(venue), do: [credentials: credentials(venue), sandbox: true]

  defp credentials("lighter") do
    Credentials.new!(api_key: "0", secret: @dummy_lighter_secret, password: "password", uid: "1")
  end

  defp credentials(_venue) do
    Credentials.new!(
      api_key: @dummy_evm_address,
      secret: @dummy_evm_secret,
      password: "password",
      uid: "1"
    )
  end

  defp changed_param_names(caller_params, recorded_params) when is_map(caller_params) and is_map(recorded_params) do
    recorded_params
    |> Enum.flat_map(fn {name, value} -> if caller_params[name] == value, do: [], else: [name] end)
    |> Enum.sort()
  end

  defp changed_param_names(caller_params, _recorded_params) do
    raise ArgumentError, "recorded caller inputs must be a map, got: #{inspect(caller_params)}"
  end

  defp emitted?(name, shapes) do
    Enum.any?(shapes, fn
      shape when is_map(shape) -> Map.has_key?(shape, name)
      _shape -> false
    end)
  end

  defp validate_injections!(injections) do
    Enum.each(injections, fn {{venue, method}, injection} ->
      params = injection["params"]
      exempt = injection["exempt_params"]

      ensure!(is_list(params) and params != [], "#{venue}.#{method} injection must name params")
      ensure!(is_list(exempt), "#{venue}.#{method} injection must enumerate exempt params")
      ensure!(exempt -- params == [], "#{venue}.#{method} exempts an unregistered param")
      ensure!(is_binary(injection["reason"]) and injection["reason"] != "", "#{venue}.#{method} injection needs a reason")
    end)
  end

  defp named_difference(observed, expected) do
    observed
    |> Kernel.++(expected)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp stale_registry_message(observed, injections) do
    stale = Map.keys(injections) -- Map.keys(observed)
    "capture param-injection registry differs from recordings: #{inspect(stale)}"
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)
end
