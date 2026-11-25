defmodule Bourse.LogRedactionTest do
  # The default handler is VM-global, so this cannot run concurrently with
  # tests that log.
  use ExUnit.Case, async: false

  @secret "k9QwE7redactionprobe0000000000000000000000000000000000000000000"
  @url "wss://fstream.example.test/ws/" <> @secret
  @handler :bourse_log_redaction_probe

  defmodule Holder do
    @moduledoc false
    use GenServer

    def init(state), do: {:ok, state}
    def handle_cast(:die, state), do: {:stop, {:transport_closed, state.url}, state}
  end

  setup do
    path = Path.join(System.tmp_dir!(), "bourse_log_redaction_#{System.unique_integer([:positive])}.log")

    # The same handler module and formatter the default handler uses, writing
    # to a file instead of the terminal.
    {:ok, default} = :logger.get_handler_config(:default)

    config = %{
      config: %{type: :file, file: String.to_charlist(path)},
      formatter: default.formatter,
      level: :all
    }

    :ok = :logger.add_handler(@handler, :logger_std_h, config)

    on_exit(fn ->
      :logger.remove_handler(@handler)
      File.rm(path)
    end)

    %{path: path}
  end

  test "the filter is installed as a primary filter by the application" do
    assert Keyword.has_key?(:logger.get_primary_config().filters, Bourse.LogRedaction.filter_id())
  end

  test "a termination report names the transport host and not the credential in its URL", %{path: path} do
    state = %{url: @url, config: %ZenWebsocket.Config{url: @url}, headers: [{"x", ~c"" ++ @url}]}
    {:ok, pid} = GenServer.start(Holder, state)
    ref = Process.monitor(pid)

    GenServer.cast(pid, :die)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:transport_closed, @url}}

    log = read_flushed(path, "terminating")

    assert log =~ "wss://fstream.example.test/[REDACTED]"
    refute log =~ @secret
  end

  test "events that are not termination reports pass through untouched" do
    event = %{level: :info, msg: {:string, @url}, meta: %{}}
    assert Bourse.LogRedaction.filter(event, []) == event
  end

  test "redact/1 keeps scheme and host and walks structs, tuples and improper lists" do
    term = {[@url | "tail " <> @url], %ZenWebsocket.Config{url: @url <> "?listenKey=" <> @secret}}

    {[a | b], %ZenWebsocket.Config{url: c}} = Bourse.LogRedaction.redact(term)

    assert a == "wss://fstream.example.test/[REDACTED]"
    assert b == "tail wss://fstream.example.test/[REDACTED]"
    assert c == "wss://fstream.example.test/[REDACTED]"
  end

  # The handler writes asynchronously; wait until the report has landed.
  defp read_flushed(path, marker, attempts \\ 50) do
    :logger_std_h.filesync(@handler)
    log = File.read!(path)

    cond do
      log =~ marker -> log
      attempts == 0 -> flunk("no termination report reached the default-format handler:\n" <> log)
      true -> Process.sleep(20) && read_flushed(path, marker, attempts - 1)
    end
  end
end
