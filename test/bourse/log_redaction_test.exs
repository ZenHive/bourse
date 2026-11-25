defmodule LogRedactionUnrelatedWorker do
  @moduledoc false
  # A host process outside the Bourse and ZenWebsocket namespaces.
  use GenServer

  def init(state), do: {:ok, state}
  def handle_cast(:die, state), do: {:stop, {:transport_closed, state.url}, state}
end

defmodule LogRedactionConsumerWorker do
  @moduledoc false
  # A host process outside Bourse whose state is a `Bourse.WS` struct.
  use GenServer

  def init(url), do: {:ok, %Bourse.WS{exchange: nil, zen_client: nil, section: :public, url: url}}
  def handle_cast(:die, state), do: {:stop, :closed, state}
end

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

  test "a termination report of a process outside Bourse and ZenWebsocket is left as it is", %{path: path} do
    {:ok, pid} = GenServer.start(LogRedactionUnrelatedWorker, %{url: @url})
    ref = Process.monitor(pid)

    GenServer.cast(pid, :die)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:transport_closed, @url}}

    assert read_flushed(path, "terminating") =~ @url
  end

  test "a host process holding a Bourse struct as its state is the host's, not Bourse's", %{path: path} do
    {:ok, pid} = GenServer.start(LogRedactionConsumerWorker, @url)
    ref = Process.monitor(pid)

    GenServer.cast(pid, :die)
    assert_receive {:DOWN, ^ref, :process, ^pid, :closed}

    assert read_flushed(path, "terminating") =~ @url
  end

  test "the filter rewrites only reports that name a Bourse or ZenWebsocket process" do
    terminate = fn state -> event(%{label: {:gen_server, :terminate}, state: state, reason: :closed}) end
    assert Bourse.LogRedaction.filter(terminate.(%{url: @url}), []) == :ignore

    assert %{msg: {:report, %{state: own}}} =
             Bourse.LogRedaction.filter(
               terminate.(%Bourse.WS{exchange: nil, zen_client: nil, section: :public, url: @url}),
               []
             )

    assert own.url == "wss://fstream.example.test/[REDACTED]"
    assert %{msg: {:report, _}} = Bourse.LogRedaction.filter(terminate.(%ZenWebsocket.Config{url: @url}), [])

    crash = fn module ->
      event(%{label: {:proc_lib, :crash}, report: [[initial_call: {module, :init, 1}, error_info: @url], []]})
    end

    assert %{msg: {:report, _}} = Bourse.LogRedaction.filter(crash.(Adapter), [])
    assert Bourse.LogRedaction.filter(crash.(LogRedactionUnrelatedWorker), []) == :ignore

    child = fn module ->
      offender = [pid: self(), id: :child, mfargs: {module, :start_link, [@url]}]
      event(%{label: {:supervisor, :child_terminated}, report: [supervisor: :sup, reason: :closed, offender: offender]})
    end

    assert %{msg: {:report, _}} = Bourse.LogRedaction.filter(child.(ConnectionOwner), [])
    assert Bourse.LogRedaction.filter(child.(LogRedactionUnrelatedWorker), []) == :ignore
  end

  test "the filter leaves every event it does not rewrite to the host's filtering policy" do
    assert Bourse.LogRedaction.filter(%{level: :info, msg: {:string, @url}, meta: %{}}, []) == :ignore

    progress = %{label: {:supervisor, :progress}, report: [started: [id: :child, pid: self()]]}
    assert Bourse.LogRedaction.filter(%{level: :info, msg: {:report, progress}, meta: %{}}, []) == :ignore

    unchanged =
      event(%{
        label: {:gen_server, :terminate},
        state: %Bourse.WS{exchange: nil, zen_client: nil, section: :public, url: "/no-scheme"},
        reason: :normal
      })

    assert Bourse.LogRedaction.filter(unchanged, []) == :ignore
  end

  test "config :bourse, :redact_termination_reports, false leaves the filter uninstalled" do
    on_exit(fn ->
      Application.delete_env(:bourse, :redact_termination_reports)
      :ok = Application.stop(:bourse)
      {:ok, _} = Application.ensure_all_started(:bourse)
    end)

    Application.put_env(:bourse, :redact_termination_reports, false)
    :ok = Application.stop(:bourse)
    {:ok, _} = Application.ensure_all_started(:bourse)
    refute Bourse.LogRedaction.installed?()
  end

  defp event(report), do: %{level: :error, msg: {:report, report}, meta: %{}}

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
