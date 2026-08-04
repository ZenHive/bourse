defmodule Bourse.ResponseTransformerTest do
  @moduledoc "Tests for Bourse.ResponseTransformer — pre-parser response shape normalization."

  use ExUnit.Case, async: true

  alias Bourse.ResponseTransformer

  @moduletag capture_log: true

  doctest ResponseTransformer

  describe "transform/2 — no-op and unknown" do
    test "nil transformer returns body unchanged" do
      assert ResponseTransformer.transform(%{"a" => 1}, nil) == %{"a" => 1}
    end

    test "unknown transformer logs a warning and returns body unchanged" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert ResponseTransformer.transform(%{"a" => 1}, :bogus) == %{"a" => 1}
        end)

      assert log =~ "Unknown transformer"
    end
  end

  describe ":unwrap_single_element_list" do
    test "unwraps a single-element list of a map" do
      assert ResponseTransformer.transform([%{"x" => 1}], :unwrap_single_element_list) == %{"x" => 1}
    end

    test "leaves empty list unchanged" do
      assert ResponseTransformer.transform([], :unwrap_single_element_list) == []
    end

    test "leaves multi-element list unchanged" do
      assert ResponseTransformer.transform([%{a: 1}, %{b: 2}], :unwrap_single_element_list) ==
               [%{a: 1}, %{b: 2}]
    end

    test "leaves a single non-map element unchanged" do
      assert ResponseTransformer.transform([42], :unwrap_single_element_list) == [42]
    end
  end

  describe ":unwrap_single_element_map" do
    test "unwraps single-key map to its value" do
      assert ResponseTransformer.transform(%{"K" => %{"a" => 1}}, :unwrap_single_element_map) ==
               %{"a" => 1}
    end

    test "leaves 2+ key maps unchanged" do
      assert ResponseTransformer.transform(%{"a" => 1, "b" => 2}, :unwrap_single_element_map) ==
               %{"a" => 1, "b" => 2}
    end

    test "leaves non-map unchanged" do
      assert ResponseTransformer.transform("x", :unwrap_single_element_map) == "x"
    end
  end

  describe ":extract_first_list_value" do
    test "returns first list value, ignoring metadata keys" do
      body = %{"XXBTZUSD" => [[1], [2]], "last" => "123"}
      assert ResponseTransformer.transform(body, :extract_first_list_value) == [[1], [2]]
    end

    test "returns map unchanged when no list values exist" do
      assert ResponseTransformer.transform(%{"a" => 1}, :extract_first_list_value) == %{"a" => 1}
    end
  end

  describe ":order_book_from_flat_list" do
    test "splits flat order list into sorted bids/asks" do
      orders = [
        %{"side" => "Sell", "price" => 100.5, "size" => 10},
        %{"side" => "Sell", "price" => 101.0, "size" => 5},
        %{"side" => "Buy", "price" => 99.5, "size" => 20},
        %{"side" => "Buy", "price" => 99.0, "size" => 7}
      ]

      assert ResponseTransformer.transform(orders, :order_book_from_flat_list) == %{
               "bids" => [[99.5, 20], [99.0, 7]],
               "asks" => [[100.5, 10], [101.0, 5]]
             }
    end

    test "skips orders with unknown sides" do
      orders = [
        %{"side" => "Buy", "price" => 1, "size" => 1},
        %{"side" => "huh", "price" => 2, "size" => 2}
      ]

      assert ResponseTransformer.transform(orders, :order_book_from_flat_list) == %{
               "bids" => [[1, 1]],
               "asks" => []
             }
    end

    test "leaves non-list unchanged" do
      assert ResponseTransformer.transform(%{"a" => 1}, :order_book_from_flat_list) == %{"a" => 1}
    end
  end

  describe "{:extract_path, path}" do
    test "walks nested envelope" do
      body = %{"retCode" => 0, "result" => %{"list" => [[1, 2]]}}
      assert ResponseTransformer.transform(body, {:extract_path, ["result", "list"]}) == [[1, 2]]
    end

    test "stops and returns current level when key missing" do
      assert ResponseTransformer.transform(%{"a" => 1}, {:extract_path, ["missing"]}) == %{"a" => 1}
    end
  end

  describe "{:extract_path_unwrap, path}" do
    test "extracts then unwraps single-element list" do
      body = %{"result" => [%{"id" => 1}]}
      assert ResponseTransformer.transform(body, {:extract_path_unwrap, ["result"]}) == %{"id" => 1}
    end

    test "returns nil when extracted list is empty" do
      body = %{"result" => []}
      assert ResponseTransformer.transform(body, {:extract_path_unwrap, ["result"]}) == nil
    end
  end

  describe "{:extract_path_unwrap_map, path}" do
    test "extracts then unwraps single-key map" do
      body = %{"result" => %{"XBTUSD" => %{"last" => 1}}}

      assert ResponseTransformer.transform(body, {:extract_path_unwrap_map, ["result"]}) ==
               %{"last" => 1}
    end
  end

  describe "{:extract_path_unwrap_merge, path, merge_keys}" do
    test "merges envelope keys into the unwrapped result (inner fields win)" do
      body = %{"time" => 111, "id" => "env", "result" => [%{"id" => "inner", "px" => 1}]}

      result =
        ResponseTransformer.transform(
          body,
          {:extract_path_unwrap_merge, ["result"], ["time", "id"]}
        )

      # inner "id" wins via put_new; "time" is merged from the envelope
      assert result == %{"id" => "inner", "px" => 1, "time" => 111}
    end

    test "returns nil when extracted list is empty" do
      body = %{"time" => 1, "result" => []}

      assert ResponseTransformer.transform(body, {:extract_path_unwrap_merge, ["result"], ["time"]}) ==
               nil
    end

    test "passes through non-map extracted value" do
      body = %{"result" => [1, 2]}

      assert ResponseTransformer.transform(body, {:extract_path_unwrap_merge, ["result"], ["x"]}) ==
               [1, 2]
    end
  end

  describe "{:positional_to_maps, field_names}" do
    test "zips positional arrays into maps" do
      rows = [["50000", "0.01", "b"], ["51000", "0.02", "s"]]

      assert ResponseTransformer.transform(rows, {:positional_to_maps, ["price", "amount", "side"]}) ==
               [
                 %{"price" => "50000", "amount" => "0.01", "side" => "b"},
                 %{"price" => "51000", "amount" => "0.02", "side" => "s"}
               ]
    end

    test "leaves non-list rows in place" do
      assert ResponseTransformer.transform([%{"a" => 1}], {:positional_to_maps, ["a"]}) ==
               [%{"a" => 1}]
    end
  end

  describe "{:transpose_columns_to_rows, column_keys}" do
    test "transposes column-oriented map into rows" do
      data = %{"ticks" => [1, 2], "open" => [10, 20]}

      assert ResponseTransformer.transform(data, {:transpose_columns_to_rows, ["ticks", "open"]}) ==
               [[1, 10], [2, 20]]
    end

    test "returns data unchanged when a column is missing" do
      data = %{"ticks" => [1, 2]}

      assert ResponseTransformer.transform(data, {:transpose_columns_to_rows, ["ticks", "open"]}) ==
               data
    end
  end

  describe "{:compose, transformers}" do
    test "chains transformers left to right" do
      # envelope extraction → transpose columns to rows
      body = %{"result" => %{"t" => [1, 2], "o" => [9, 8]}}

      transformer =
        {:compose, [{:extract_path, ["result"]}, {:transpose_columns_to_rows, ["t", "o"]}]}

      assert ResponseTransformer.transform(body, transformer) == [[1, 9], [2, 8]]
    end

    test "empty transformer list is identity" do
      assert ResponseTransformer.transform(%{"a" => 1}, {:compose, []}) == %{"a" => 1}
    end
  end
end
