defmodule Bourse.LogRedactionTest do
  # The default handler is VM-global, so this cannot run concurrently with
  # tests that log.
  use ExUnit.Case, async: false

  alias Bourse.WS.Adapter
  alias Bourse.WS.ConnectionOwner
  alias ZenWebsocket.Client

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

  test "the filter leaves every event it does not rewrite to the host's filtering policy" do
    assert Bourse.LogRedaction.filter(%{level: :info, msg: {:string, @url}, meta: %{}}, []) == :ignore

    progress = %{label: {:supervisor, :progress}, report: [started: [id: :child, pid: self()]]}
    assert Bourse.LogRedaction.filter(%{level: :info, msg: {:report, progress}, meta: %{}}, []) == :ignore
  end

  test "redact/1 keeps scheme and host and walks structs, tuples and improper lists" do
    term = {[@url | "tail " <> @url], %ZenWebsocket.Config{url: @url <> "?listenKey=" <> @secret}}

    {[a | b], %ZenWebsocket.Config{url: c}} = Bourse.LogRedaction.redact(term)

    assert a == "wss://fstream.example.test/[REDACTED]"
    assert b == "tail wss://fstream.example.test/[REDACTED]"
    assert c == "wss://fstream.example.test/[REDACTED]"
  end

  describe "reports from Bourse's own processes" do
    setup do
      test_pid = self()
      # Primary filters run newest first: reinstalling Bourse's filter after the
      # probe puts the probe behind it, where it sees each event as Bourse's
      # filter left it, including the SASL reports the default handler drops.
      :ok = Bourse.LogRedaction.uninstall()
      :ok = :logger.add_primary_filter(:bourse_log_redaction_probe, {&__MODULE__.Probe.filter/2, test_pid})
      :ok = Bourse.LogRedaction.install()
      on_exit(fn -> :logger.remove_primary_filter(:bourse_log_redaction_probe) end)
    end

    test "an adapter's termination report and its proc_lib crash report carry no credential", %{path: path} do
      {:ok, transport} = Agent.start(fn -> nil end)
      url = @url <> "?listenKey=" <> @secret
      session = %{listen_key: @secret, keepalive_endpoint: :fapiPrivate_put_listenkey, keepalive_ms: 60_000}

      ws = %Bourse.WS{
        exchange: Bourse.Exchange.new!("binanceusdm"),
        section: :private,
        url: url,
        zen_client: %Client{server_pid: transport, url: url},
        auth: %{pattern: :listen_key, meta: session}
      }

      {:ok, adapter} = Adapter.start_link(ws.exchange, :private, connect: false, ws: ws)
      Process.unlink(adapter)

      refute inspect(:sys.get_status(adapter)) =~ @secret

      ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(adapter, {:transport_closed, String.to_charlist(url)}) end)

      assert_receive {:raw_event, {:gen_server, :terminate}, report}
      refute report =~ @secret
      assert_receive {:raw_event, {:proc_lib, :crash}, report}
      refute report =~ @secret
      refute read_flushed(path, "terminating") =~ @secret
    end

    test "a connection owner's termination and supervisor reports carry no credential", %{path: path} do
      {:ok, transport} = Agent.start(fn -> nil end)
      client = %Client{server_pid: transport, url: @url}
      {:ok, owner} = ConnectionOwner.start(@url, client)

      refute inspect(:sys.get_status(owner)) =~ @secret

      ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(owner, {:transport_closed, @url}) end)

      assert_receive {:raw_event, {:gen_server, :terminate}, report}
      refute report =~ @secret
      assert_receive {:raw_event, {:supervisor, :child_terminated}, report}
      refute report =~ @secret
      refute read_flushed(path, "terminating") =~ @secret
    end
  end

  describe "registration" do
    setup do
      on_exit(fn ->
        :logger.remove_primary_filter(Bourse.LogRedaction.filter_id())
        :ok = Bourse.LogRedaction.install()
      end)
    end

    test "a filter registered under the same id by someone else is neither replaced nor removed" do
      :ok = Bourse.LogRedaction.uninstall()
      foreign = {fn _event, _ -> :ignore end, :foreign}
      :ok = :logger.add_primary_filter(Bourse.LogRedaction.filter_id(), foreign)

      assert Bourse.LogRedaction.install() == {:error, {:filter_id_taken, Bourse.LogRedaction.filter_id()}}
      assert :ok = Bourse.LogRedaction.uninstall()

      assert {_id, ^foreign} = List.keyfind(:logger.get_primary_config().filters, Bourse.LogRedaction.filter_id(), 0)
    end

    test "install and uninstall are idempotent for its own filter" do
      assert :ok = Bourse.LogRedaction.install()
      assert Bourse.LogRedaction.installed?()
      assert :ok = Bourse.LogRedaction.uninstall()
      refute Bourse.LogRedaction.installed?()
      assert :ok = Bourse.LogRedaction.uninstall()
    end
  end

  test "redact/1 covers userinfo, http queries, charlists, map keys, URI structs and credential fields" do
    term = %{
      ("wss://u:" <> @secret <> "@fstream.example.test/ws") =>
        ~c"wss://fstream.example.test/ws/" ++ String.to_charlist(@secret),
      https: "GET https://fapi.example.test/fapi/v1/listenKey?signature=" <> @secret,
      uri: URI.parse(@url <> "?k=" <> @secret),
      session: %{"listenKey" => @secret, listen_key: @secret, keepalive_ms: 1}
    }

    redacted = Bourse.LogRedaction.redact(term)

    refute inspect(redacted) =~ @secret
    assert redacted.session.keepalive_ms == 1
    assert redacted.https == "GET https://fapi.example.test/[REDACTED]"
    assert redacted.uri.host == "fstream.example.test"
    assert redacted["wss://fstream.example.test/[REDACTED]"] == ~c"wss://fstream.example.test/[REDACTED]"
    refute Bourse.LogRedaction.inspect({:closed, @url}) =~ @secret
  end

  defmodule Probe do
    @moduledoc false
    def filter(%{msg: {:report, %{label: label} = report}}, pid) do
      send(pid, {:raw_event, label, inspect(report, limit: :infinity, printable_limit: :infinity)})
      :ignore
    end

    def filter(_event, _pid), do: :ignore
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
