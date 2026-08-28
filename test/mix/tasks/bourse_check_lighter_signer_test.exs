defmodule Mix.Tasks.Bourse.CheckLighterSignerTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.CheckLighterSigner

  test "toolchain detection names missing executables without running native checks" do
    assert {:error, missing} = CheckLighterSigner.toolchain(fn _name -> nil end)
    assert "go" in missing
    assert length(missing) == 2
  end

  test "cannot-run path raises Mix.Error and pins the non-zero mix exit" do
    error =
      assert_raise Mix.Error, fn ->
        CheckLighterSigner.run_with(fn _name -> nil end)
      end

    message = Exception.message(error)

    assert message =~ "cannot run: missing go"
    assert message =~ "mix bourse.build_lighter_signer"
    assert message =~ "C compiler"
  end

  test "mix exits non-zero on the cannot-run path, so check.dispatch records a failing step" do
    # Observes the real Mix.Error -> System.halt mapping rather than echoing the
    # constant: without this, "the gate is red without Go" is an untested claim.
    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["run", "--no-start", "-e", "Mix.Tasks.Bourse.CheckLighterSigner.run_with(fn _name -> nil end)"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == CheckLighterSigner.cannot_run_exit_status()
    assert status != 0
    assert output =~ "Lighter native verification cannot run"
  end

  test "toolchain detection accepts resolved Go and C executables" do
    assert {:ok, ["go", _compiler]} = CheckLighterSigner.toolchain(&"/toolchain/#{&1}")
  end

  test "coverage parser measures only the C parser and framing ranges" do
    gcov = """
    function take_bytes called 2 returned 100% blocks executed 100%
        1:   85:static int take_bytes(void) {
    #####:   86:  return 0;
        -:  194:
    function send_signed_result called 1 returned 100% blocks executed 100%
    #####:  250:excluded response-allocation fallback
    function process_init called 1 returned 100% blocks executed 100%
        2:  289:static int process_init(void) {
    """

    assert %{covered: 2, executable: 3, percentage: percentage} =
             CheckLighterSigner.coverage_percentage(gcov)

    assert_in_delta percentage, 66.67, 0.01
  end

  test "coverage parser rejects reports without the measured C functions" do
    assert_raise Mix.Error, ~r/contained no Lighter C parser/, fn ->
      CheckLighterSigner.coverage_percentage("Lines executed:100.00% of 1")
    end
  end
end
