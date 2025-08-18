defmodule Sifter.Test.Repo.Migrations.CreateSifterTestTables do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS unaccent")
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    create table(:organizations) do
      add(:name, :text, null: false)
      timestamps()
    end

    create table(:events) do
      add(:name, :text, null: false)
      add(:description, :text)
      add(:status, :text, null: false)
      add(:priority, :integer)
      add(:active, :boolean, default: true)
      add(:time_start, :utc_datetime)
      add(:time_end, :utc_datetime)
      add(:organization_id, references(:organizations), null: true)
      timestamps()
    end

    create(index(:events, [:organization_id]))

    execute("""
    ALTER TABLE events
      ADD COLUMN searchable tsvector
      GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, ''))
      ) STORED;
    """)

    create(index(:events, [:searchable], using: :gin))

    create table(:tags) do
      add(:name, :text, null: false)
      timestamps()
    end

    create table(:event_tags) do
      add(:tag_id, references(:tags), null: true)
      add(:event_id, references(:events), null: true)
      timestamps()
    end
  end

  def down do
    drop(table(:event_tags))
    drop(table(:tags))
    drop(table(:events))
    drop(table(:organizations))
  end
end