defmodule Bourse.Test.TestnetSnapshot do
  @moduledoc """
  Snapshot and restore for the process-global `Bourse.Testnet` credential registry.

  `test/test_helper.exs` registers every provider-live credential once at boot and
  raises when one is absent, so the whole suite depends on that registry staying
  populated. A test that clears or restarts it therefore removes credentials its
  siblings need, and — because the registry is global and the wipe is not undone —
  every credential-consuming test scheduled *after* it in the current seed order
  fails with `No credentials registered for <venue>`.

  That failure is textually identical to the one `test_helper.exs` raises for a
  genuinely unset credential, and it is seed-dependent, so it reads as a flake and
  is healed by `mix test.json`'s auto-retry. The suite then reports green while its
  first pass proved nothing — the exact false green this provider-live suite exists
  to prevent.

  Wrap any test that must wipe the registry:

      setup do
        snapshot = Bourse.Test.TestnetSnapshot.capture()
        on_exit(fn -> Bourse.Test.TestnetSnapshot.restore(snapshot) end)
        Bourse.Testnet.clear()
        :ok
      end

  `restore/1` re-registers exactly what `capture/0` saw, so it stays correct as
  venues are added — unlike a hand-maintained list of venues to put back.
  """

  alias Bourse.Credentials
  alias Bourse.Testnet

  @type entry :: {atom(), atom(), Credentials.t()}

  @doc """
  Captures every currently registered credential as `{exchange, sandbox_key, credentials}`.

  Returns `[]` when the registry is not running, so a test that stops it can still
  restore from a snapshot taken beforehand.
  """
  @spec capture() :: [entry()]
  def capture do
    if Testnet.started?() do
      for {exchange, sandbox_key} <- Testnet.registered_exchanges(),
          credentials = Testnet.creds(exchange, sandbox_key) do
        {exchange, sandbox_key, credentials}
      end
    else
      []
    end
  end

  @doc """
  Restores a snapshot, starting the registry first when a test stopped it.

  The registry is cleared before re-registering so the result is exactly the
  snapshot, never the snapshot merged over whatever the test left behind.
  """
  @spec restore([entry()]) :: :ok
  def restore(snapshot) when is_list(snapshot) do
    ensure_started!()
    Testnet.clear()

    Enum.each(snapshot, fn {exchange, sandbox_key, credentials} ->
      :ok = Testnet.register(exchange, sandbox_key, register_opts(credentials))
    end)
  end

  defp ensure_started! do
    if Testnet.started?() do
      :ok
    else
      {:ok, pid} = Testnet.start_link([])
      # The calling on_exit process dies right after this callback; leaving the
      # link would take the restarted registry down with it.
      Process.unlink(pid)
      :ok
    end
  end

  defp register_opts(%Credentials{} = credentials) do
    [api_key: credentials.api_key, secret: credentials.secret, sandbox: credentials.sandbox]
    |> put_present(:password, credentials.password)
    |> put_present(:uid, credentials.uid)
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: [{key, value} | opts]
end
