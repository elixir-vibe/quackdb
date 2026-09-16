defmodule QuackDB.Ecto.TextTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.Text

  test "contains accepts explicit case sensitivity" do
    query = from(event in "events", select: contains(event.name, "D%_", case_sensitive: false))

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT contains(lower(q0."name"), lower('D%_')) FROM "events" AS q0]
  end

  test "rejects unsupported containment options" do
    assert_raise ArgumentError, ~r/contains\/3 expects/, fn ->
      Code.compile_string("""
      defmodule InvalidContainsOptions do
        use QuackDB.Ecto
        def query, do: from(t in "events", select: contains(t.name, "x", typo: false))
      end
      """)
    end
  end

  test "builds text helper expressions" do
    query =
      from(event in "events",
        where:
          contains(event.name, "duck") and starts_with(event.kind, "b") and
            ends_with(event.kind, "d") and prefix(event.name, "du") and suffix(event.name, "ck"),
        select: %{
          name: event.name,
          contains_text: contains_text(event.name, "duck"),
          part: split_part(event.name, "-", 2),
          words: string_split(event.name, " "),
          regex_words: string_split_regex(event.name, "\\s+"),
          regex_words_with_options: string_split_regex(event.name, "\\s+", "i")
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."name" AS "name", contains(q0."name", 'duck') AS "contains_text", split_part(q0."name", '-', 2) AS "part", string_split(q0."name", ' ') AS "words", string_split_regex(q0."name", '\s+') AS "regex_words", string_split_regex(q0."name", '\s+', 'i') AS "regex_words_with_options" FROM "events" AS q0 WHERE ((((contains(q0."name", 'duck') AND starts_with(q0."kind", 'b')) AND ends_with(q0."kind", 'd')) AND prefix(q0."name", 'du')) AND suffix(q0."name", 'ck'))]
  end
end
