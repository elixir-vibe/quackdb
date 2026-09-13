defmodule QuackDB.Integration.ParameterTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper
  import QuackDB.SQL.Fragment, only: [table: 1, column_list: 1]

  alias QuackDB.IntegrationRepo, as: Repo
  alias QuackDB.TestSchemas.ParameterRecord

  @moduletag :integration
  @fields [:id, :body, :tags, :nested, :occurred_at, :occurred_tz, :payload, :attachments]

  test "direct parameters survive persisted round trips without changing bytes or precision" do
    connection = start_connection!()
    name = unique_table("parameter_direct")
    create_table!(connection, name, ParameterRecord)

    for record <- records() do
      params = Enum.map(@fields, &parameter(record, &1))

      QuackDB.query!(
        connection,
        [
          "INSERT INTO ",
          table(name),
          " (",
          column_list(@fields),
          ") VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        ],
        params
      )
    end

    result =
      QuackDB.query!(connection, [
        "SELECT ",
        column_list(@fields),
        " FROM ",
        table(name),
        " ORDER BY id"
      ])

    assert result.rows ==
             Enum.map(records(), fn record -> Enum.map(@fields, &Map.fetch!(record, &1)) end)
  end

  test "Ecto insert, update and query pins preserve risky parameter values" do
    start_repo!()
    name = unique_table("parameter_ecto")
    create_table!(Repo, name, ParameterRecord)

    for record <- records() do
      ParameterRecord
      |> struct!(record)
      |> Ecto.put_meta(source: name)
      |> Repo.insert!()
    end

    query = from(record in {name, ParameterRecord}, order_by: record.id)
    assert Enum.map(Repo.all(query), &Map.take(&1, @fields)) == records()

    body = "Updated: " <> hd(records()).body
    record = Repo.one!(from(record in {name, ParameterRecord}, where: record.id == 1))
    payload = ~S(\x41 is literal binary data, not the byte A)
    record |> Ecto.Changeset.change(body: body, payload: payload) |> Repo.update!()

    assert %{body: ^body, payload: ^payload} =
             Repo.one!(
               from(record in {name, ParameterRecord},
                 where: record.body == ^body and record.payload == ^payload
               )
             )
  end

  test "Ecto bulk SQL and native append preserve typed binary parameters" do
    start_repo!()

    for options <- [[], [insert_method: :append], [insert_method: :append, append_shape: :rows]] do
      name = unique_table("parameter_bulk")
      create_table!(Repo, name, ParameterRecord)
      assert {4, nil} = Repo.insert_all({name, ParameterRecord}, records(), options)
      query = from(record in {name, ParameterRecord}, order_by: record.id)
      assert Enum.map(Repo.all(query), &Map.take(&1, @fields)) == records()
    end
  end

  test "direct timestamp parameters normalize non-UTC offsets without losing microseconds" do
    connection = start_connection!()

    value = %{
      ~U[2024-01-02 03:04:05.123456Z]
      | utc_offset: 19_800,
        time_zone: "Fixed/+0530",
        zone_abbr: "+0530"
    }

    create_table!(connection, "offset_parameter", occurred_at: :timestamptz)
    QuackDB.query!(connection, "INSERT INTO offset_parameter VALUES (?)", [value])

    assert %{rows: [[~U[2024-01-01 21:34:05.123456Z]]]} =
             QuackDB.query!(connection, "SELECT occurred_at FROM offset_parameter")
  end

  defp parameter(%{payload: nil}, :payload), do: nil
  defp parameter(record, :payload), do: {:blob, record.payload}
  defp parameter(%{attachments: nil}, :attachments), do: nil

  defp parameter(record, :attachments),
    do:
      Enum.map(record.attachments, fn
        nil -> nil
        bytes -> {:blob, bytes}
      end)

  defp parameter(record, field), do: Map.fetch!(record, field)

  defp records do
    markdown =
      "# Привет 🦆\r\n\nIt's \"quoted\"; `C:\\tasks\\file`\n```sql\nSELECT '?'; -- $1 /* ? */\n```\nRobert'); DROP TABLE users;--\tCafe\u0301"

    [
      %{
        id: 1,
        body: markdown,
        tags: [markdown, nil, "", "🦆"],
        nested: [[1, nil], [], nil],
        occurred_at: ~N[2024-02-29 23:59:59.123456],
        occurred_tz: ~U[2024-02-29 23:59:59.654321Z],
        payload: markdown,
        attachments: [markdown, nil, <<0, 255>>]
      },
      %{
        id: 2,
        body: "",
        tags: [],
        nested: [],
        occurred_at: ~N[1970-01-01 00:00:00.000001],
        occurred_tz: ~U[1970-01-01 00:00:00.000001Z],
        payload: <<0, 1, 127, 128, 255>>,
        attachments: []
      },
      %{
        id: 3,
        body: nil,
        tags: nil,
        nested: nil,
        occurred_at: nil,
        occurred_tz: nil,
        payload: nil,
        attachments: nil
      },
      %{
        id: 4,
        body: "end\n",
        tags: [nil],
        nested: [[nil]],
        occurred_at: nil,
        occurred_tz: nil,
        payload: "",
        attachments: [""]
      }
    ]
  end
end
