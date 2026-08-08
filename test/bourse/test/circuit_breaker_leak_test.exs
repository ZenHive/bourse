# Regression cover for the fuse leak that made the offline suite report a
# rotating set of flaky failures (roadmap task 559).
#
# `Bourse.CircuitBreaker.fuse_name/1` resolves to a single global atom per venue
# and `:fuse` holds that state for the lifetime of the node, so a test that melts
# a venue left it open for every later test on that venue, in every module. The
# victim rotated with the seed, which is what made it read as flakiness.
#
# The two modules below are each meaningful on their own, so neither depends on
# ExUnit's module ordering: the first proves a melting test cleans up after
# itself, and the second proves that a module which never enables the breaker
# cannot melt anything in the first place.

defmodule Bourse.Test.CircuitBreakerLeakMeltTest do
  use ExUnit.Case, async: false

  alias Bourse.CircuitBreaker
  alias Bourse.Test.CircuitBreakerControl

  # A real runtime venue: fuse names resolve through Bourse.Registry, so an
  # arbitrary id would exercise only the nil/no-op path.
  @venue "deribit"

  test "a test that blows a fuse hands the next module a closed circuit" do
    # Registered *before* the opt-in so it runs last: ExUnit runs `on_exit`
    # callbacks in reverse order of registration, so this one observes the state
    # after `enable!/1`'s own cleanup, which is exactly what the next module
    # inherits. Calling `remove_installed_fuses/0` inline here instead would only
    # assert this test's tidiness — the registered callback is the thing that
    # actually protects the suite, and deleting it from `enable!/1` has to turn
    # this red.
    on_exit(fn ->
      assert CircuitBreaker.status(@venue) == :not_installed,
             "enable!/1's on_exit left #{@venue} installed — the next module inherits a leaked fuse"

      assert CircuitBreaker.check(@venue) == :ok
    end)

    CircuitBreakerControl.isolate!(@venue)

    assert CircuitBreaker.check(@venue) == :ok
    Enum.each(1..10, fn _failure -> CircuitBreaker.record_failure(@venue) end)
    assert CircuitBreaker.status(@venue) == :blown
  end
end

defmodule Bourse.Test.CircuitBreakerOptInIsSyncTest do
  use ExUnit.Case, async: false

  # `CircuitBreakerControl.enable!/1` re-enables the breaker with a global
  # `Application.put_env` and, on exit, removes *every* installed fuse. Both are
  # process-global, so the opt-in is only non-interfering while its callers run
  # alone: ExUnit drains all async modules before it starts a sync one, and runs
  # sync modules one at a time. Add the opt-in to an `async: true` module and the
  # `put_env` re-arms the breaker for every module running beside it — restoring
  # exactly the ambient coupling `config/config.exs` removed — while the cleanup
  # yanks fuses out from under them.
  #
  # That invariant held only because the four current callers happen to be sync,
  # and nothing asserted it. This is the assertion: the safety of the opt-in is a
  # property of the whole test tree, so no single module can be trusted to defend
  # it. A file is flagged on any `async: true`, without proving which module in it
  # calls the control — the conservative reading is the useful one here, since a
  # file that mixes an async module with a breaker opt-in is itself the hazard.
  test "no test module that opts into the circuit breaker runs async" do
    offenders =
      "test/**/*.exs"
      |> Path.wildcard()
      |> Enum.map(&{&1, File.read!(&1)})
      |> Enum.filter(fn {_path, source} -> source =~ "CircuitBreakerControl." end)
      # Anchored to the `use` declaration rather than the bare phrase: prose that
      # merely discusses `async: true` (this file's own comment, for one) is not
      # a module that runs concurrently.
      |> Enum.filter(fn {_path, source} -> source =~ ~r/^\s*use\s+.*async:\s*true/m end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == [],
           """
           These test files opt into the circuit breaker and declare `async: true`:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Enabling the breaker is process-global and its cleanup removes every
           installed fuse, so the opting-in module must run alone. Declare the
           module `async: false`, or drop the `CircuitBreakerControl` call.
           """
  end
end

defmodule Bourse.Test.CircuitBreakerLeakVictimTest do
  use ExUnit.Case, async: false

  alias Bourse.CircuitBreaker

  @venue "deribit"

  test "a module that never enables the breaker cannot melt a fuse" do
    assert CircuitBreaker.check(@venue) == :ok

    Enum.each(1..10, fn _failure -> CircuitBreaker.record_failure(@venue) end)

    # The `:test` environment disables the breaker, so melting is a no-op and no
    # fuse is ever installed. This is the structural half of the guarantee: a
    # newly added test cannot leak, whether or not its author knows about fuses.
    assert CircuitBreaker.status(@venue) == :not_installed
    assert CircuitBreaker.check(@venue) == :ok
  end
end
