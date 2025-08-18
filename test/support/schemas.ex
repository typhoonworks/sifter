defmodule Sifter.Test.Schemas.Organization do
  use Ecto.Schema
  @primary_key {:id, :id, autogenerate: true}

  schema "organizations" do
    field(:name, :string)
    has_many(:events, Sifter.Test.Schemas.Event)
    timestamps()
  end
end

defmodule Sifter.Test.Schemas.Tag do
  use Ecto.Schema
  @primary_key {:id, :id, autogenerate: true}

  schema "tags" do
    field(:name, :string)
    timestamps()
  end
end

defmodule Sifter.Test.Schemas.EventTag do
  use Ecto.Schema
  @primary_key {:id, :id, autogenerate: true}

  schema "event_tags" do
    belongs_to(:event, Sifter.Test.Schemas.Event)
    belongs_to(:tag, Sifter.Test.Schemas.Tag)
    timestamps()
  end
end

defmodule Sifter.Test.Schemas.Event do
  use Ecto.Schema
  @primary_key {:id, :id, autogenerate: true}

  schema "events" do
    field(:name, :string)
    field(:description, :string)
    field(:status, :string)
    field(:priority, :integer)
    field(:active, :boolean, default: true)
    field(:time_start, :utc_datetime)
    field(:time_end, :utc_datetime)
    belongs_to(:organization, Sifter.Test.Schemas.Organization)

    many_to_many(:tags, Sifter.Test.Schemas.Tag,
      join_through: Sifter.Test.Schemas.EventTag,
      on_replace: :delete
    )

    timestamps()
  end
end
