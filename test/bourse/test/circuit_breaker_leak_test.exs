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
    CircuitBreakerControl.isolate!(@venue)

    assert CircuitBreaker.check(@venue) == :ok
    Enum.each(1..10, fn _failure -> CircuitBreaker.record_failure(@venue) end)
    assert CircuitBreaker.status(@venue) == :blown

    # Standing in for the next module: the cleanup `enable!/1` registers is what
    # a later test would otherwise trip over, so run it and assert the venue is
    # closed again. Without it this venue stays blown for the rest of the node.
    CircuitBreakerControl.remove_installed_fuses()

    assert CircuitBreaker.status(@venue) == :not_installed
    assert CircuitBreaker.check(@venue) == :ok
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
