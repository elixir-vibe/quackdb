defmodule QuackDB.Ecto.ListTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.List

  test "generates list function fragments" do
    query =
      from(event in "events",
        where:
          contains_list(event.terms, ^42) and has_any(event.terms, ^[1, 2]) and
            has_all(event.terms, ^[1]),
        select: %{term: unnest(event.terms)}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT unnest(q0."terms") AS "term" FROM "events" AS q0 WHERE ((list_contains(q0."terms", ?) AND list_has_any(q0."terms", ?)) AND list_has_all(q0."terms", ?))]
  end
end
