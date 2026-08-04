if Bourse.Test.Generator.OptIn.requested?([:network, :invalid_creds]) do
  defmodule Bourse.InvalidCredsProbeTest do
    @moduledoc """
    Task 67 — Invalid-Credentials Private-Pipeline Probe.

    Opt-in suite: file-level `@moduletag :network` keeps the default
    `mix test` run offline. To execute:

        mix test.json --quiet --only network test/bourse/invalid_creds_probe_test.exs

    Expect a mix of passes (exchange returned an auth-shaped error) and
    `⚠️  INCONCLUSIVE` Logger warnings for rate-limit / geo-block cases.
    Zero flunks on an otherwise-healthy network means the full private
    pipeline (DNS → URL resolution → signing → transport → error parsing)
    is working end-to-end.
    """

    use ExUnit.Case, async: false
    use Bourse.Test.Generator.InvalidCredsProbe

    @moduletag :network
    @moduletag :invalid_creds
  end
end
