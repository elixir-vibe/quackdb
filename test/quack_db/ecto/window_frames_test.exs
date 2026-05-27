defmodule QuackDB.Ecto.WindowFramesTest do
  use ExUnit.Case, async: true

  import QuackDB.Ecto.WindowFrames

  test "expands frame helpers to Ecto fragments" do
    assert {:fragment, _, ["ROWS BETWEEN 6 PRECEDING AND CURRENT ROW"]} =
             Macro.expand_once(quote(do: rows_between({:preceding, 6}, :current_row)), __ENV__)

    assert {:fragment, _, ["RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING"]} =
             Macro.expand_once(
               quote(do: range_between(:unbounded_preceding, {:following, 1})),
               __ENV__
             )

    assert {:fragment, _, ["GROUPS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING"]} =
             Macro.expand_once(
               quote(do: groups_between(:current_row, :unbounded_following)),
               __ENV__
             )
  end

  test "rejects unsupported bounds" do
    assert_raise ArgumentError, ~r/unsupported window frame bound/, fn ->
      Code.eval_quoted(quote(do: rows_between({:preceding, -1}, :current_row)), [], __ENV__)
    end
  end
end
