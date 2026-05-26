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

  @tag :integration
  test "Ecto.Migrator runs migrations through the adapter" do
    start_repo!()

    QuackDB.IntegrationRepo.query!("DROP TABLE IF EXISTS quackdb_migrator_events")
    QuackDB.IntegrationRepo.query!("DROP TABLE IF EXISTS schema_migrations")

    assert :ok =
             Ecto.Migrator.up(QuackDB.IntegrationRepo, 20_260_526_000_001, CreateMigratorEvents)

    assert %{rows: [["quackdb_migrator_events"]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT table_name FROM information_schema.tables WHERE table_name = 'quackdb_migrator_events'"
             )

    assert [20_260_526_000_001] =
             QuackDB.IntegrationRepo.all(from(m in "schema_migrations", select: m.version))

    assert :already_up =
             Ecto.Migrator.up(QuackDB.IntegrationRepo, 20_260_526_000_001, CreateMigratorEvents)
  end
end
