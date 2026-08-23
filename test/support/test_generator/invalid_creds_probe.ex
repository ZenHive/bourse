defmodule Bourse.Test.Generator.InvalidCredsProbe do
  @moduledoc """
  Compile-time generator for per-exchange invalid-credentials probe tests (Task 67).

  Usage:

      defmodule Bourse.InvalidCredsProbeTest do
        use ExUnit.Case, async: false
        @moduletag :network
        @moduletag :invalid_creds
        use Bourse.Test.Generator.InvalidCredsProbe
      end

  At compile time, iterates `Bourse.Registry.exchanges/0`, resolves each
  exchange's generated module, skips modules without a usable private unified
  endpoint (`fetch_balance` or
  `fetch_accounts`), and emits one `test` per remaining exchange.

  The generated test body:

    1. Builds `%Bourse.Credentials{}` with bogus but structurally-valid values
       (random `INVALID_<hex>` api key, zero-filled base64 secret, placeholder
       password + uid — cheap to include unconditionally).
    2. Builds `%Bourse.Exchange{}` against production URLs (sandbox deliberately
       not requested — this is a pipeline sanity probe, not a trading test).
    3. Invokes the chosen unified method via `apply(Bourse, method, [exchange])`.
    4. Classifies the response:

       * **pass** — `{:error, %Bourse.Error{type: t}}` where `t` ∈
         `[:authentication_error, :permission_denied]`. Proves the full
         pipeline reached the exchange, the signature was rejected as
         expected, and the error was parsed into our unified shape.
       * **inconclusive** — rate limit, network, exchange unavailable,
         access restricted (geo block). Logged as a warning, does not flunk.
       * **fail** — `{:ok, _}` (signature accepted despite bogus key — real
         bug) or any unrelated error (pipeline broke before reaching auth,
         or error classification is wrong).

  File-level `@moduletag :network` on the consuming test module gates the
  suite behind `--only network`; `mix test.json` without flags skips it.
  """

  alias Bourse.Registry
  alias Bourse.Test.Generator.TagAtoms

  # Unified methods that (a) take no required positional params beyond the
  # exchange and (b) are private on every exchange that exposes them.
  # Ordered by coverage — fetch_balance is supported by virtually every
  # exchange; fetch_accounts is the fallback for the handful that don't.
  @candidate_methods [:fetch_balance, :fetch_accounts]

  defmacro __using__(_opts) do
    exchanges = collect_exchanges()

    test_blocks =
      for {exchange_id, _module, method} <- exchanges do
        build_test(exchange_id, method)
      end

    quote do
      require Logger

      unquote_splicing(test_blocks)
    end
  end

  # Compile-time exchange filter. Returns `[{id, module, method}]` for every
  # exchange where (1) the module is compiled, (2) signing is explicitly
  # authored, and (3) at least one candidate method is mapped.
  defp collect_exchanges do
    Registry.exchanges()
    |> Enum.map(fn id ->
      module = Registry.module_for(id)
      pattern = if module, do: fetch_pattern(module)
      method = if module, do: pick_method(module)
      {id, module, pattern, method}
    end)
    |> Enum.filter(fn {_id, module, pattern, method} ->
      module != nil and pattern != nil and method != nil
    end)
    |> Enum.map(fn {id, module, _pattern, method} -> {id, module, method} end)
  end

  defp fetch_pattern(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__signing__, 0) do
      Map.get(module.__signing__(), :pattern)
    end
  end

  defp pick_method(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__unified_endpoint__, 1) do
      Enum.find(@candidate_methods, fn method ->
        module.__unified_endpoint__(method) != []
      end)
    end
  end

  defp build_test(exchange_id, method) do
    tag_atom = TagAtoms.exchange_tag!(exchange_id)
    id_atom = String.to_existing_atom(exchange_id)

    quote do
      @tag :invalid_creds
      @tag unquote(tag_atom)
      test "#{unquote(exchange_id)} rejects invalid credentials on #{unquote(method)}" do
        creds = unquote(__MODULE__).__build_invalid_creds__()

        exchange =
          try do
            Bourse.Exchange.new!(unquote(id_atom), credentials: creds)
          rescue
            # reach:disable-next-line bare_rescue -- Exchange.new! never raises in normal operation; any exception here IS the test failure (flunk formats it), so narrowing the rescue would defeat the diagnostic
            err ->
              flunk("""
              #{unquote(exchange_id)}: Exchange.new! raised — not an auth probe failure:
                #{Exception.message(err)}
              """)
          end

        result = apply(Bourse, unquote(method), [exchange])

        unquote(__MODULE__).__classify__(
          unquote(exchange_id),
          unquote(method),
          result
        )
      end
    end
  end

  # =========================================================================
  # Runtime helpers — called from generated test bodies.
  # =========================================================================

  @doc """
  Builds a fresh `%Bourse.Credentials{}` with deterministically-invalid fields for
  probe tests. Public (not `defp`) because it is invoked from macro-generated
  test bodies in consumer modules. The random suffix on `api_key` prevents any
  exchange-side caching of known-bad keys from short-circuiting the signing
  path. Password/uid are populated unconditionally; they are harmless for
  exchanges that do not require them.
  """
  def __build_invalid_creds__ do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %Bourse.Credentials{
      api_key: "INVALID_" <> suffix,
      # Base64 of 32 zero bytes — valid base64 for patterns that decode
      # secrets (Kraken-style). Bytes themselves are meaningless.
      secret: Base.encode64(<<0::256>>),
      password: "INVALID_PASSPHRASE",
      uid: "INVALID_UID"
    }
  end

  @doc """
  Classifies a probe call result into pass / inconclusive / flunk. Public
  because generated test bodies call it directly. Auth-shaped errors pass;
  rate-limit / network / unavailable / geo-block errors log and pass as
  inconclusive; everything else flunks with a diagnostic. Keep the accepted
  type set in sync with `Bourse.Error` and the inconclusive lists in
  `Bourse.IntegrationHelper`.
  """
  def __classify__(exchange_id, method, result) do
    import ExUnit.Assertions

    case result do
      {:error, %Bourse.Error{type: t}} when t in [:authentication_error, :permission_denied] ->
        :ok

      {:error, %Bourse.Error{type: t} = err}
      when t in [
             :rate_limit_exceeded,
             :network_error,
             :exchange_not_available,
             :access_restricted
           ] ->
        __log_inconclusive__(exchange_id, method, err)
        :ok

      {:ok, _} ->
        flunk("""
        #{exchange_id}.#{method} returned {:ok, _} with bogus credentials.
        The signature pipeline or the exchange accepted INVALID_<random> as a valid key.
        This is a real bug — either our signing is non-deterministic or the exchange
        isn't actually validating what we're sending.
        """)

      {:error, %Bourse.Error{} = err} ->
        flunk("""
        #{exchange_id}.#{method} returned an unexpected error type.
          expected: :authentication_error | :permission_denied (auth-shaped)
          got type: #{inspect(err.type)}
          code:     #{inspect(err.code)}
          message:  #{inspect(err.message)}

        This usually means the pipeline broke before reaching auth (wrong URL,
        request malformed, error classifier mismapped the exchange response).
        """)

      {:error, other} ->
        flunk("""
        #{exchange_id}.#{method} returned an unclassified error:
          #{inspect(other, limit: :infinity, printable_limit: 2000)}

        Expected a %Bourse.Error{}. The dispatch layer is leaking raw errors.
        """)

      other ->
        flunk("""
        #{exchange_id}.#{method} returned an unexpected shape:
          #{inspect(other, limit: :infinity, printable_limit: 2000)}
        """)
    end
  end

  @doc """
  Logs a warning for an inconclusive probe result. Public because the classifier
  calls it from inside macro-generated test bodies; kept out of `defp` so it can
  be traced / overridden during debugging.
  """
  def __log_inconclusive__(exchange_id, method, %Bourse.Error{type: type, message: msg}) do
    require Logger

    Logger.warning("""
    ⚠️  INCONCLUSIVE: #{exchange_id}.#{method} returned #{type}: #{inspect(msg)}
    Treating as infrastructure issue (rate limit / network / geo block), not a pipeline bug.
    """)
  end
end
