defmodule Mix.Tasks.Bourse.CheckLighterSignerTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.CheckLighterSigner

  test "toolchain detection names missing executables without running native checks" do
    assert {:error, missing} = CheckLighterSigner.toolchain(fn _name -> nil end)
    assert "go" in missing
    assert length(missing) == 2
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
