defmodule QuackDB.Integration.Ecto.DuckDB2MigrationTest do
  use ExUnit.Case

  import Ecto.Query
  import QuackDB.QuackServerCase

  alias QuackDB.IntegrationRepo, as: Repo

  @moduletag :integration

  defmodule CreateScoreTrigger do
    use Ecto.Migration

    alias QuackDB.DDL

    def up do
      create table(:duckdb2_trigger_scores, primary_key: false) do
        add(:id, :integer)
        add(:score, :integer)
      end

      create table(:duckdb2_trigger_totals, primary_key: false) do
        add(:total, :bigint)
      end

      execute("INSERT INTO duckdb2_trigger_totals VALUES (0)")

      execute(
        DDL.create_trigger(
          :sum_scores,
          :duckdb2_trigger_scores,
          "UPDATE duckdb2_trigger_totals SET total = total + (SELECT sum(score) FROM inserted)",
          event: :insert,
          referencing: [new_table: :inserted]
        )
      )
    end

    def down do
      execute(DDL.drop_trigger(:sum_scores, :duckdb2_trigger_scores))
      drop(table(:duckdb2_trigger_totals))
      drop(table(:duckdb2_trigger_scores))
    end
  end

  defmodule CreateNestedSchema do
    use Ecto.Migration

    alias QuackDB.DDL

    def up do
      execute(DDL.create_schema(:duckdb2_finance))
      execute(DDL.create_schema([:duckdb2_finance, :reports]))
      execute(DDL.create_table({[:duckdb2_finance, :reports], :ledger}, amount: :integer))
    end

    def down, do: execute(DDL.drop_schema(:duckdb2_finance, cascade: true))
  end

  setup do
    start_repo!()
    Repo.query!(QuackDB.DDL.drop_table("schema_migrations", if_exists: true))
    :ok
  end

  test "migrations create triggers with QuackDB.DDL" do
    assert :ok = Ecto.Migrator.up(Repo, 20_261_026_000_001, CreateScoreTrigger, log: false)

    try do
      Repo.insert_all("duckdb2_trigger_scores", [[id: 1, score: 10], [id: 2, score: 32]])
      assert [42] = Repo.all(from(totals in "duckdb2_trigger_totals", select: totals.total))
    after
      Ecto.Migrator.down(Repo, 20_261_026_000_001, CreateScoreTrigger, log: false)
    end
  end

  test "migrations create nested schemas with QuackDB.DDL" do
    assert :ok = Ecto.Migrator.up(Repo, 20_261_026_000_002, CreateNestedSchema, log: false)

    try do
      Repo.query!("INSERT INTO duckdb2_finance.reports.ledger VALUES (40), (2)")

      assert [42] =
               Repo.all(
                 from(ledger in "ledger",
                   prefix: "duckdb2_finance.reports",
                   select: sum(ledger.amount)
                 )
               )
    after
      Ecto.Migrator.down(Repo, 20_261_026_000_002, CreateNestedSchema, log: false)
    end
  end
end
