defmodule QuackDB.Integration.NestedParameterTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper
  import QuackDB.SQL.Fragment, only: [table: 1]

  alias QuackDB.IntegrationRepo, as: Repo
  alias QuackDB.TestSchemas.NestedRecord

  @moduletag :integration

  test "SQL and both native append shapes preserve maps, enum arrays and SQL NULLs" do
    start_repo!()

    for options <- [[], [insert_method: :append], [insert_method: :append, append_shape: :rows]] do
      name = unique_table("nested_parameters")

      create_table!(Repo, name,
        id: :integer,
        payload: :json,
        payloads: {:list, :json},
        nested_payloads: {:list, {:list, :json}},
        states: {:list, :varchar},
        priorities: {:list, :integer}
      )

      rows = [
        %{id: 1, payload: nil, payloads: nil, nested_payloads: nil, states: nil, priorities: nil},
        %{id: 2, payload: %{}, payloads: [], nested_payloads: [], states: [], priorities: []},
        %{
          id: 3,
          payload: %{"nested" => [nil, "🦆", "quoted'\\text"]},
          payloads: [nil, %{"a" => 1}],
          nested_payloads: [nil, [], [nil, %{"b" => true}]],
          states: [:queued, nil, :done],
          priorities: [:low, nil, :high]
        }
      ]

      assert {3, nil} = Repo.insert_all({name, NestedRecord}, rows, options)
      loaded = Repo.all(from(record in {name, NestedRecord}, order_by: record.id))
      assert Enum.map(loaded, &Map.take(&1, Map.keys(hd(rows)))) == rows

      assert %{rows: [[true, true, true, true, true]]} =
               Repo.query!([
                 "SELECT payload IS NULL, payloads IS NULL, nested_payloads IS NULL, states IS NULL, priorities IS NULL FROM ",
                 table(name),
                 " WHERE id = 1"
               ])

      assert %{rows: [[true, true, ["queued", nil, "done"], [1, nil, 2]]]} =
               Repo.query!([
                 "SELECT payloads[1] IS NULL, nested_payloads[3][1] IS NULL, states, priorities FROM ",
                 table(name),
                 " WHERE id = 3"
               ])

      [_, _, record] = loaded
      record |> Ecto.Changeset.change(payload: nil) |> Repo.update!()

      assert %{rows: [[true]]} =
               Repo.query!(["SELECT payload IS NULL FROM ", table(name), " WHERE id = 3"])
    end
  end
end
