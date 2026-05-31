defmodule QuackDB.Ecto.ConditionalsTest do
  use ExUnit.Case, async: true

  defmodule Queries do
    use QuackDB.Ecto

    def tier_query do
      from(event in "events",
        select: %{
          tier:
            case_when do
              event.score >= 90 -> "high"
              event.score >= 50 -> "medium"
              true -> "low"
            end
        }
      )
    end
  end

  test "builds CASE expressions with case_when syntax" do
    assert Queries.tier_query() |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT CASE WHEN (q0."score" >= ?) THEN 'high' WHEN (q0."score" >= ?) THEN 'medium' ELSE 'low' END AS "tier" FROM "events" AS q0]
  end

  test "requires a final true clause" do
    assert_raise ArgumentError, ~r/final true -> expression clause/, fn ->
      defmodule MissingElseQuery do
        use QuackDB.Ecto

        def query do
          from(event in "events",
            select:
              case_when do
                event.score >= 90 -> "high"
              end
          )
        end
      end
    end
  end
end
