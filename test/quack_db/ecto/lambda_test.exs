defmodule QuackDB.Ecto.LambdaTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.List

  test "generates DuckDB list lambda functions" do
    min_score = 10

    query =
      from(event in "events",
        select: %{
          filtered: list_filter(event.scores, fn x -> x > ^min_score and not is_nil(x) end),
          indexed: list_filter(event.scores, fn x, i -> x > i end),
          doubled: list_transform(event.scores, fn x -> x * 2 end),
          shifted: list_transform(event.scores, fn x, i -> x + i end),
          total: list_reduce(event.scores, fn acc, x -> acc + x end),
          indexed_total: list_reduce(event.scores, fn acc, x, i -> acc + x + i end),
          initial_total: list_reduce(event.scores, fn acc, x -> acc + x end, 0)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT list_filter(q0."scores", lambda x : ((x > ?) AND (x IS NOT NULL))) AS "filtered", list_filter(q0."scores", lambda x, i : (x > i)) AS "indexed", list_transform(q0."scores", lambda x : (x * 2)) AS "doubled", list_transform(q0."scores", lambda x, i : (x + i)) AS "shifted", list_reduce(q0."scores", lambda acc, x : (acc + x)) AS "total", list_reduce(q0."scores", lambda acc, x, i : ((acc + x) + i)) AS "indexed_total", list_reduce(q0."scores", lambda acc, x : (acc + x), 0) AS "initial_total" FROM "events" AS q0]
  end

  test "generates supported lambda literals and operators" do
    query =
      from(event in "events",
        select: %{
          negative: list_transform(event.scores, fn x -> -x end),
          quotient: list_transform(event.scores, fn x -> x / 2 end),
          modulo: list_filter(event.scores, fn x -> rem(x, 2) == 0 end),
          nils: list_filter(event.scores, fn x -> is_nil(x) or x != 0 end),
          strings: list_filter(event.names, fn name -> name == "duck" end),
          tiers:
            list_transform(event.scores, fn x ->
              case_when do
                x >= 90 -> "high"
                x >= 50 -> "medium"
                true -> "low"
              end
            end)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT list_transform(q0."scores", lambda x : (-x)) AS "negative", list_transform(q0."scores", lambda x : (x / 2)) AS "quotient", list_filter(q0."scores", lambda x : ((x % 2) = 0)) AS "modulo", list_filter(q0."scores", lambda x : ((x IS NULL) OR (x != 0))) AS "nils", list_filter(q0."names", lambda name : (name = 'duck')) AS "strings", list_transform(q0."scores", lambda x : CASE WHEN (x >= 90) THEN 'high' WHEN (x >= 50) THEN 'medium' ELSE 'low' END) AS "tiers" FROM "events" AS q0]
  end

  test "raises clear errors for unsupported lambda forms" do
    assert_raise ArgumentError, ~r/expected list_filter\/2 lambda as `fn x -> expr end`/, fn ->
      defmodule InvalidLambdaShape do
        import Ecto.Query
        import QuackDB.Ecto.List

        def query do
          from(event in "events", select: list_filter(event.scores, event.score > 0))
        end
      end
    end

    assert_raise ArgumentError,
                 ~r/unsupported list_filter\/2 lambda arity 3; expected 1 or 2 parameters/,
                 fn ->
                   defmodule InvalidLambdaArity do
                     import Ecto.Query
                     import QuackDB.Ecto.List

                     def query do
                       from(event in "events",
                         select: list_filter(event.scores, fn x, y, z -> x + y + z end)
                       )
                     end
                   end
                 end

    assert_raise ArgumentError,
                 ~r/unknown DuckDB lambda variable `min_score` in list_filter\/2/,
                 fn ->
                   defmodule InvalidLambdaVariable do
                     import Ecto.Query
                     import QuackDB.Ecto.List

                     def query do
                       from(event in "events",
                         select: list_filter(event.scores, fn x -> x > min_score end)
                       )
                     end
                   end
                 end

    assert_raise ArgumentError,
                 ~r/unsupported DuckDB lambda expression in list_transform\/2: String.downcase\(x\)/,
                 fn ->
                   defmodule InvalidLambdaCall do
                     import Ecto.Query
                     import QuackDB.Ecto.List

                     def query do
                       from(event in "events",
                         select: list_transform(event.names, fn x -> String.downcase(x) end)
                       )
                     end
                   end
                 end
  end
end
