defmodule Mix.Tasks.Bourse.CheckLighterSigner do
  @shortdoc "Builds and verifies the Lighter native signer; fails when the toolchain is missing"

  @moduledoc """
  Runs the pinned Go golden vectors and the BEAM-to-C native helper tests.

  A missing Go or C compiler is a RED: `priv/native/lighter_signer/` is a
  gitignored build artifact of `mix bourse.build_lighter_signer`, so a host
  without that toolchain cannot run the signer and this check must not report
  a pass. Mix maps the raised `Mix.Error` to a non-zero process exit.
  """

  use Mix.Task

  alias Mix.Tasks.Bourse.BuildLighterSigner

  @project_root Path.expand("../../..", __DIR__)
  @source_dir Path.join(@project_root, "native/lighter_signer")
  @native_test "test/bourse/signing/lighter_native_test.exs"
  @critical_coverage_percentage 95.0
  @covered_functions ~w(
    read_u16_be read_u32_be read_u64_be write_u16_be write_u32_be
    take_bytes take_u8 take_u16 take_u32 take_i64 exhausted
    read_exact read_frame write_frame write_response_header send_success send_error
    process_init process_auth_token process_create_order process_cancel_order
    process_cancel_all_orders process_modify_order process_update_leverage
    process_update_margin process_frame
  )

  # Mix.CLI maps Mix.Error to System.halt(1). Tests pin this constant as the
  # cannot-run exit code of `mix bourse.check_lighter_signer`.
  @cannot_run_exit_status 1

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]), do: run_with(&System.find_executable/1)

  def run(args), do: Mix.raise("Unexpected arguments: #{inspect(args)}")

  @doc "Exit code Mix reports when this task raises on a missing toolchain."
  @spec cannot_run_exit_status() :: 1
  def cannot_run_exit_status, do: @cannot_run_exit_status

  @doc "Runs the check with an injectable executable lookup, for the cannot-run test."
  @spec run_with((String.t() -> String.t() | nil)) :: :ok
  def run_with(find_executable) when is_function(find_executable, 1) do
    case toolchain(find_executable) do
      {:ok, _executables} ->
        verify_native!(find_executable)

      {:error, missing} ->
        Mix.raise(cannot_run_message(missing))
    end
  end

  @doc "Reports whether Go and the platform C compiler can be resolved."
  @spec toolchain((String.t() -> String.t() | nil)) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def toolchain(find_executable) when is_function(find_executable, 1) do
    names = ["go", compiler()]
    missing = Enum.reject(names, &find_executable.(&1))

    if missing == [], do: {:ok, names}, else: {:error, missing}
  end

  @doc "Calculates coverage for the named C parser and framing functions in a gcov report."
  @spec coverage_percentage(String.t()) :: %{
          covered: non_neg_integer(),
          executable: non_neg_integer(),
          percentage: float()
        }
  def coverage_percentage(gcov) do
    {_inside_covered_function?, covered, executable} =
      gcov
      |> String.split("\n")
      |> Enum.reduce({false, 0, 0}, fn line, counts -> coverage_line(line, counts) end)

    if executable == 0, do: Mix.raise("gcov report contained no Lighter C parser or framing functions")
    %{covered: covered, executable: executable, percentage: covered / executable * 100.0}
  end

  defp verify_native!(find_executable) do
    coverage? = not is_nil(find_executable.("gcov"))
    build_args = if coverage?, do: ["--coverage"], else: []

    clear_coverage_data()
    Mix.Task.run("bourse.build_lighter_signer", build_args)
    run!("go", ["test", "./..."], @source_dir)
    run_native_tests!()
    if coverage?, do: check_c_coverage!()
    :ok
  end

  defp cannot_run_message(missing) do
    """
    Lighter native verification cannot run: missing #{Enum.join(missing, ", ")}.

    The helper under priv/native/lighter_signer/ is a gitignored build artifact.
    Install Go 1.25+ and a C compiler, then:

      mix bourse.build_lighter_signer

    mix check.dispatch records this as a failing step. A missing toolchain is a
    RED, not a skipped pass.
    """
  end

  defp run_native_tests! do
    mix = System.find_executable("mix") || Mix.raise("could not find mix executable")
    run!(mix, ["test.json", "--quiet", "--include", "native", @native_test], @project_root, [{"MIX_ENV", "test"}])
  end

  defp check_c_coverage! do
    output_dir = BuildLighterSigner.output_dir(BuildLighterSigner.host_target())
    gcno = output_dir |> Path.join("*-helper.gcno") |> Path.wildcard() |> one_coverage_file!("gcno")
    gcov = System.find_executable("gcov") || Mix.raise("could not find gcov executable")
    gcov_report = run_output!(gcov, ["-t", "-b", "-c", "-o", gcno, "csrc/helper.c"], @source_dir)
    report = coverage_percentage(gcov_report)

    Mix.shell().info(
      "Lighter C parser/framing coverage: #{Float.round(report.percentage, 2)}% " <>
        "(#{report.covered}/#{report.executable} executable lines)"
    )

    if report.percentage < @critical_coverage_percentage do
      Mix.raise("Lighter C parser/framing coverage is below #{@critical_coverage_percentage}%")
    end
  end

  defp coverage_line(line, {inside?, covered, executable}) do
    case function_name(line) do
      {:ok, name} ->
        {name in @covered_functions, covered, executable}

      :error ->
        count_coverage(line, inside?, covered, executable)
    end
  end

  defp count_coverage(line, inside?, covered, executable) do
    case {inside?, String.split(line, ":", parts: 3)} do
      {true, [count, _line_number, _source]} ->
        case String.trim(count) do
          "-" -> {inside?, covered, executable}
          "#####" -> {inside?, covered, executable + 1}
          "=====" -> {inside?, covered, executable + 1}
          _execution_count -> {inside?, covered + 1, executable + 1}
        end

      _other ->
        {inside?, covered, executable}
    end
  end

  defp function_name(line) do
    case String.split(line, " ", trim: true) do
      ["function", name | _details] ->
        {:ok, name}

      _other ->
        :error
    end
  end

  defp clear_coverage_data do
    target = BuildLighterSigner.host_target()
    output_dir = BuildLighterSigner.output_dir(target)
    current_prefix = target |> BuildLighterSigner.executable_name() |> Path.rootname()

    gcda = output_dir |> Path.join("*.gcda") |> Path.wildcard()

    # A pre-rename checkout can carry a stale <old-name>-helper.gcno that would
    # collide with the exactly-one gcno check after the next coverage build.
    stale_gcno =
      output_dir
      |> Path.join("*-helper.gcno")
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(Path.basename(&1), current_prefix))

    Enum.each(gcda ++ stale_gcno, &File.rm/1)
  end

  defp one_coverage_file!([path], _extension), do: path
  defp one_coverage_file!(_paths, extension), do: Mix.raise("expected one Lighter C .#{extension} coverage file")

  defp run!(executable, args, working_dir, env \\ []) do
    output = run_output!(executable, args, working_dir, env)
    if output != "", do: Mix.shell().info(output)
  end

  defp run_output!(executable, args, working_dir, env \\ []) do
    case System.cmd(executable, args, cd: working_dir, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        Mix.raise("#{executable} failed with status #{status}:\n#{output}")
    end
  end

  defp compiler do
    if match?({:win32, _}, :os.type()), do: "gcc", else: "cc"
  end
end
