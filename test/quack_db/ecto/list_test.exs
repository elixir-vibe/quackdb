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
        select: %{
          term: unnest(event.terms),
          count: list_length(event.terms),
          first: extract(event.terms, 1),
          sorted: sort(event.terms),
          distinct_terms: distinct(event.terms),
          unique_count: unique(event.terms),
          position: position(event.terms, 42),
          slice: slice(event.terms, 1, 2),
          stepped_slice: slice(event.terms, 1, 3, 2),
          overlap: intersect_list(event.terms, ^[2, 3]),
          concatenated: concat(event.terms, ^[4])
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT unnest(q0."terms") AS "term", len(q0."terms") AS "count", list_extract(q0."terms", 1) AS "first", list_sort(q0."terms") AS "sorted", list_distinct(q0."terms") AS "distinct_terms", list_unique(q0."terms") AS "unique_count", list_position(q0."terms", 42) AS "position", list_slice(q0."terms", 1, 2) AS "slice", list_slice(q0."terms", 1, 3, 2) AS "stepped_slice", list_intersect(q0."terms", ?) AS "overlap", list_concat(q0."terms", ?) AS "concatenated" FROM "events" AS q0 WHERE ((list_contains(q0."terms", ?) AND list_has_any(q0."terms", ?)) AND list_has_all(q0."terms", ?))]
  end
end
