defmodule Mix.Tasks.Ccxt.BuildLighterSigner do
  @shortdoc "Builds the pinned official Lighter signer and Port helper"

  @moduledoc """
  Builds the official Lighter Go C-shared library and its generated header,
  then links the isolated Port helper for the current release target.

      mix ccxt.build_lighter_signer

  The Go module pins the exact lighter-go revision selected by Task 198.
  """

  use Mix.Task

  @switches [target: :string, coverage: :boolean]
  @supported_targets ~w(darwin-arm64 linux-amd64 linux-arm64 windows-amd64)
  @source_dir Path.expand("../../../native/lighter_signer", __DIR__)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    ensure_valid_args!(invalid)

    target = Keyword.get(opts, :target, host_target())
    coverage? = Keyword.get(opts, :coverage, false)
    ensure_supported_target!(target)
    ensure_host_target!(target)

    source_dir = source_dir()
    output_dir = output_dir(target)
    File.mkdir_p!(output_dir)

    library_path = Path.join(output_dir, library_name(target))

    run!("go", ["mod", "verify"], source_dir)

    run!(
      "go",
      ["build", "-buildmode=c-shared", "-o", library_path, "github.com/elliottech/lighter-go/sharedlib"],
      source_dir
    )

    prepare_library!(target, library_path, source_dir)
    build_helper!(target, source_dir, output_dir, library_path, coverage?)

    Mix.shell().info("Built Lighter signer for #{target} in #{output_dir}")
    :ok
  end

  @doc "Returns the packaged Lighter signer source directory."
  @spec source_dir() :: String.t()
  def source_dir, do: @source_dir

  @doc "Returns the runtime output directory for a supported target."
  @spec output_dir(String.t()) :: String.t()
  def output_dir(target) do
    Application.app_dir(:bourse, ["priv", "native", "lighter_signer", target])
  end

  @doc "Returns the native target identifier for the current host."
  @spec host_target() :: String.t()
  def host_target do
    system_architecture = List.to_string(:erlang.system_info(:system_architecture))

    target_for(:os.type(), system_architecture, System.get_env())
  end

  @doc """
  Resolves a release target from an explicit host description.

  Windows reports a `:system_architecture` of `"win32"` — the OS, not the CPU —
  so on that platform the architecture comes from the environment the Windows
  loader populates instead. Taking the host as arguments keeps every branch
  reachable from a test on any one machine.
  """
  @spec target_for({:unix | :win32, atom()}, String.t(), %{optional(String.t()) => String.t()}) ::
          String.t()
  def target_for(os_type, system_architecture, env \\ %{})

  def target_for({:unix, :darwin}, system_architecture, _env) do
    "darwin-" <> architecture(system_architecture)
  end

  def target_for({:unix, _name}, system_architecture, _env) do
    "linux-" <> architecture(system_architecture)
  end

  def target_for({:win32, _name}, _system_architecture, env) do
    "windows-" <> windows_architecture(env)
  end

  defp build_helper!(target, source_dir, output_dir, library_path, coverage?) do
    compiler = if String.starts_with?(target, "windows-"), do: "gcc", else: "cc"
    executable = Path.join(output_dir, executable_name(target))

    args =
      ["-std=c11"]
      |> Kernel.++(coverage_args(coverage?))
      |> Kernel.++(["-Wall", "-Wextra", "-Werror", "-I", output_dir, Path.join(source_dir, "csrc/helper.c")])
      |> Kernel.++(linker_args(target, output_dir, library_path))
      |> Kernel.++(["-o", executable])

    run!(compiler, args, source_dir)
  end

  defp prepare_library!("darwin-" <> _arch, library_path, source_dir) do
    run!("install_name_tool", ["-id", "@rpath/liblighter_signer.dylib", library_path], source_dir)
  end

  defp prepare_library!(_target, _library_path, _source_dir), do: :ok

  defp linker_args("darwin-" <> _arch, output_dir, _library_path) do
    ["-L", output_dir, "-llighter_signer", "-Wl,-rpath,@loader_path"]
  end

  defp linker_args("linux-" <> _arch, output_dir, _library_path) do
    ["-L", output_dir, "-llighter_signer", "-Wl,-rpath,$ORIGIN"]
  end

  defp linker_args("windows-" <> _arch, _output_dir, library_path), do: [library_path]

  defp run!(executable, args, working_dir) do
    case System.cmd(executable, args, cd: working_dir, stderr_to_stdout: true) do
      {output, 0} ->
        if output != "", do: Mix.shell().info(output)

      {output, status} ->
        Mix.raise("#{executable} failed with status #{status}:\n#{output}")
    end
  end

  defp architecture(system_architecture) do
    cond do
      String.contains?(system_architecture, ["aarch64", "arm64"]) -> "arm64"
      String.contains?(system_architecture, ["x86_64", "amd64"]) -> "amd64"
      true -> Mix.raise("Unsupported architecture: #{system_architecture}")
    end
  end

  # Under WOW64 `PROCESSOR_ARCHITECTURE` describes the emulated 32-bit process,
  # and the host CPU is disclosed as `PROCESSOR_ARCHITEW6432` instead.
  defp windows_architecture(env) do
    case env["PROCESSOR_ARCHITEW6432"] || env["PROCESSOR_ARCHITECTURE"] do
      nil ->
        Mix.raise("Cannot determine Windows architecture: PROCESSOR_ARCHITECTURE is unset")

      value ->
        value |> String.downcase() |> architecture()
    end
  end

  defp ensure_host_target!(target) do
    if target != host_target() do
      Mix.raise("Cross-compilation is unsupported; build #{target} on a #{target} runner")
    end
  end

  defp ensure_supported_target!(target) do
    if target not in @supported_targets do
      Mix.raise("Unsupported Lighter signer target #{inspect(target)}")
    end
  end

  defp ensure_valid_args!([]), do: :ok
  defp ensure_valid_args!(invalid), do: Mix.raise("Invalid options: #{inspect(invalid)}")

  defp coverage_args(true), do: ["-O0", "--coverage"]
  defp coverage_args(false), do: ["-O2"]

  defp library_name("darwin-" <> _arch), do: "liblighter_signer.dylib"
  defp library_name("linux-" <> _arch), do: "liblighter_signer.so"
  defp library_name("windows-" <> _arch), do: "liblighter_signer.dll"

  @doc false
  def executable_name("windows-" <> _arch), do: "bourse_lighter_signer.exe"
  def executable_name(_target), do: "bourse_lighter_signer"
end
