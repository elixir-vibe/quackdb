defmodule QuackDB.Ecto.ConditionalsTest do
  use ExUnit.Case, async: true

  defmodule Queries do
    use QuackDB.Ecto, conditionals: true

    def tier_query do
      from(event in "events",
        select: %{
          tier:
            if event.score >= 90 do
              "high"
            else
              "normal"
            end
        }
      )
    end
  end

  test "builds CASE expressions with Elixir if syntax" do
    assert Queries.tier_query() |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT CASE WHEN (q0."score" >= 90) THEN 'high' ELSE 'normal' END AS "tier" FROM "events" AS q0]
  end
end
