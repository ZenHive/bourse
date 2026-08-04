defmodule Bourse.Test.Case do
  @moduledoc """
  Shared ExUnit case template with opt-in BEAM message tracing.

  Wires `ExUnitJSON.Trace` once so process-heavy modules can opt in with
  `@moduletag trace_messages: true` (or an integer ring-buffer size for chatty
  modules). Untagged tests are a zero-cost no-op; the `trace.messages` block
  only emits on a **failing** tagged test (ex_unit_json v0.6+ flight recorder).

  Requires OTP 27+.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      setup {ExUnitJSON.Trace, :setup}
    end
  end
end
