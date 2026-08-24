defmodule QuackDB.Integration.Ecto.MigratorTest do
  use ExUnit.Case

  import Ecto.Query
  import QuackDB.QuackServerCase

  defmodule CreateMigratorEvents do
    use Ecto.Migration

    def change do
      create table(:quackdb_migrator_events, primary_key: false) do
        add(:id, :integer, primary_key: true)
        add(:name, :string, null: false)
      end

      create(index(:quackdb_migrator_events, [:name]))
    end
  end

  defmodule AddMigratorEventActive do
    use Ecto.Migration

    @disable_ddl_transaction true

    def change do
      drop(index(:quackdb_migrator_events, [:name]))

      alter table(:quackdb_migrator_events) do
        add(:active, :boolean, default: false, null: false)
      end

      create(index(:quackdb_migrator_events, [:name]))
    end
  end

  @tag :integration
  test "Ecto.Migrator runs migrations through the adapter" do
    start_repo!()

    QuackDB.IntegrationRepo.query!(
      QuackDB.DDL.drop_table("quackdb_migrator_events", if_exists: true)
    )

    QuackDB.IntegrationRepo.query!(QuackDB.DDL.drop_table("schema_migrations", if_exists: true))

    assert :ok =
             Ecto.Migrator.up(QuackDB.IntegrationRepo, 20_260_526_000_001, CreateMigratorEvents)

    assert %{rows: [["quackdb_migrator_events"]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT table_name FROM information_schema.tables WHERE table_name = 'quackdb_migrator_events'"
             )

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all("quackdb_migrator_events", [
               %{id: 1, name: "existing"}
             ])

    assert :ok =
             Ecto.Migrator.up(
               QuackDB.IntegrationRepo,
               20_260_526_000_002,
               AddMigratorEventActive
             )

    assert [[1, "existing", false]] =
             QuackDB.IntegrationRepo.all(
               from(e in "quackdb_migrator_events",
                 select: [e.id, e.name, e.active]
               )
             )

    assert [20_260_526_000_001, 20_260_526_000_002] =
             QuackDB.IntegrationRepo.all(
               from(m in "schema_migrations", order_by: m.version, select: m.version)
             )

    assert :already_up =
             Ecto.Migrator.up(QuackDB.IntegrationRepo, 20_260_526_000_001, CreateMigratorEvents)
  end
end
