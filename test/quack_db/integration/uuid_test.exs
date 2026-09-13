defmodule QuackDB.Integration.UUIDTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper
  import QuackDB.SQL.Fragment, only: [table: 1]

  alias QuackDB.IntegrationRepo, as: Repo
  alias QuackDB.TestSchemas.{CustomUUIDRecord, UUIDRecord}

  @moduletag :integration
  @uuid "550e8400-e29b-41d4-a716-446655440000"

  defp create_uuid_table!(name) do
    create_table!(Repo, name, [
      {:id, :uuid, primary_key: true},
      {:external_id, :uuid},
      {:parent_id, :uuid},
      {:related_ids, {:list, :uuid}},
      {:external_ids, {:list, :uuid}}
    ])
  end

  test "UUID schema reads, query pins and returning preserve canonical strings" do
    start_repo!()
    name = unique_table("uuid_record")
    create_uuid_table!(name)

    record =
      %UUIDRecord{
        external_id: @uuid,
        related_ids: [@uuid, nil],
        external_ids: [@uuid, nil]
      }
      |> Ecto.put_meta(source: name)
      |> Repo.insert!(returning: true)

    assert {:ok, id} = Ecto.UUID.cast(record.id)
    assert record.id == id
    query = from(record in {name, UUIDRecord})
    assert [^record] = Repo.all(query)
    assert ^record = Repo.get!(query, id)
    assert ^record = Repo.one!(from(record in query, where: record.external_id == ^@uuid))

    updated = record |> Ecto.Changeset.change(parent_id: id) |> Repo.update!(returning: true)
    assert updated.parent_id == id
    assert ^updated = Repo.get!(query, id)

    assert %{rows: [[^id, @uuid, ^id, [@uuid, nil], [@uuid, nil]]]} =
             Repo.query!([
               "SELECT id, external_id, parent_id, related_ids, external_ids FROM ",
               table(name)
             ])
  end

  test "custom UUID types round trip through schema reads, pins and returning" do
    start_repo!()
    name = unique_table("custom_uuid_record")

    create_table!(Repo, name, [
      {:id, :uuid, primary_key: true},
      {:other_id, :uuid},
      {:ids, {:list, :uuid}},
      {:checked_id, :uuid},
      {:checked_ids, {:list, :uuid}}
    ])

    uuid = CustomUUIDRecord.UUID.autogenerate()
    checked = {:uuid_v7, uuid}

    record =
      %CustomUUIDRecord{
        other_id: nil,
        ids: [uuid, nil],
        checked_id: checked,
        checked_ids: [checked, nil]
      }
      |> Ecto.put_meta(source: name)
      |> Repo.insert!(returning: true)

    assert record.id == uuid
    assert record.checked_id == checked
    assert record.checked_ids == [checked, nil]
    query = from(record in {name, CustomUUIDRecord})
    assert [^record] = Repo.all(query)
    assert ^record = Repo.get!(query, uuid)
    assert ^record = Repo.one!(from(record in query, where: record.checked_id == ^checked))

    updated =
      record
      |> Ecto.Changeset.change(other_id: uuid, checked_id: nil, checked_ids: [])
      |> Repo.update!(returning: true)

    assert updated.other_id == uuid
    assert updated.checked_id == nil
    assert updated.checked_ids == []
    assert ^updated = Repo.get!(query, uuid)

    assert %{rows: [[^uuid, ^uuid, [^uuid, nil], nil, []]]} =
             Repo.query!(["SELECT id, other_id, ids, checked_id, checked_ids FROM ", table(name)])
  end

  test "nullable UUIDs and UUID arrays round trip through bulk SQL and append" do
    start_repo!()

    for options <- [[], [insert_method: :append], [insert_method: :append, append_shape: :rows]] do
      name = unique_table("uuid_bulk")
      create_uuid_table!(name)

      rows = [
        %{
          id: "ffffffff-ffff-ffff-ffff-ffffffffffff",
          external_id: @uuid,
          parent_id: @uuid,
          related_ids: [@uuid, nil],
          external_ids: [@uuid, nil]
        },
        %{
          id: "00000000-0000-0000-0000-000000000000",
          external_id: nil,
          parent_id: nil,
          related_ids: nil,
          external_ids: []
        }
      ]

      assert {2, nil} = Repo.insert_all({name, UUIDRecord}, rows, options)

      for row <- rows do
        loaded = Repo.get!(from(record in {name, UUIDRecord}), row.id)
        assert Map.take(loaded, Map.keys(row)) == row
      end
    end
  end
end
