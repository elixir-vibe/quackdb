defmodule QuackDB.Integration.JSONAnalyticsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase

  @moduletag :integration

  test "QuackDB.Source.json/2 reads newline-delimited JSON" do
    connection = start_connection!()
    path = write_json_events!()
    source = QuackDB.Source.json(path, format: :newline_delimited)

    assert {:ok,
            %QuackDB.Result{
              columns: ["category", "name", "score", "first_tag", "kind"],
              rows: rows
            }} =
             QuackDB.query(connection, [
               "SELECT category, name, score, tags[1] AS first_tag, payload.kind AS kind FROM ",
               source,
               " ORDER BY score DESC"
             ])

    assert rows == [
             ["a", "goose", 20, "angry", "bird"],
             ["a", "duck", 10, "water", "bird"],
             ["b", "salmon", 5, "water", "fish"]
           ]
  end

  test "Ecto aggregates over JSON source helpers" do
    start_repo!()
    path = write_json_events!()
    source = QuackDB.Source.json(path, format: :newline_delimited)

    query =
      from(event in source,
        group_by: event.category,
        order_by: [asc: event.category],
        select: %{
          category: event.category,
          total_score: sum(event.score),
          count: count(event.name)
        }
      )

    assert [
             %{category: "a", total_score: 30, count: 2},
             %{category: "b", total_score: 5, count: 1}
           ] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto fragments query nested JSON-derived columns" do
    start_repo!()
    path = write_json_events!()
    source = QuackDB.Source.json(path, format: :newline_delimited)

    query =
      from(event in source,
        where: fragment("?.kind", event.payload) == "bird",
        order_by: [asc: event.name],
        select: %{
          name: event.name,
          first_tag: fragment("?[1]", event.tags),
          kind: fragment("?.kind", event.payload)
        }
      )

    assert [
             %{name: "duck", first_tag: "water", kind: "bird"},
             %{name: "goose", first_tag: "angry", kind: "bird"}
           ] = QuackDB.IntegrationRepo.all(query)
  end

  test "raw SQL JSON extraction functions decode scalar JSON results" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["name", "second_score"], rows: [["duck", "20"]]}} =
             QuackDB.query(
               connection,
               ~s|SELECT json_extract_string('{"name":"duck","scores":[10,20]}', '$.name') AS name, json_extract('{"name":"duck","scores":[10,20]}', '$.scores[1]') AS second_score|
             )
  end

  defp write_json_events! do
    path =
      Path.join(
        System.tmp_dir!(),
        "quackdb_json_events_#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, """
    {"category":"a","name":"duck","score":10,"tags":["water","bird"],"payload":{"kind":"bird"}}
    {"category":"a","name":"goose","score":20,"tags":["angry"],"payload":{"kind":"bird"}}
    {"category":"b","name":"salmon","score":5,"tags":["water"],"payload":{"kind":"fish"}}
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end
end
