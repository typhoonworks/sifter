defmodule Sifter.Fixtures do
  @moduledoc """
  Test fixtures for Sifter DB tests.
  """

  alias Sifter.Test.Repo
  alias Sifter.Test.Schemas.{Event, EventTag, Organization, Tag}

  def insert_organization(attrs \\ %{}) do
    defaults = %{
      name: "Org #{System.unique_integer([:positive])}"
    }

    attrs = Map.merge(defaults, attrs)

    %Organization{}
    |> struct(attrs)
    |> Repo.insert!()
  end

  def insert_event(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    defaults = %{
      name: "Event #{System.unique_integer([:positive])}",
      description: "some description",
      status: "draft",
      time_start: DateTime.add(now, 3600, :second),
      time_end: DateTime.add(now, 86_400, :second),
      organization_id: nil
    }

    attrs = Map.merge(defaults, attrs)

    %Event{}
    |> struct(attrs)
    |> Repo.insert!()
  end

  def insert_tag(attrs \\ %{}) do
    defaults = %{
      name: "Tag #{System.unique_integer([:positive])}"
    }

    attrs = Map.merge(defaults, attrs)

    %Tag{}
    |> struct(attrs)
    |> Repo.insert!()
  end

  def insert_event_tag(attrs \\ %{}) do
    defaults = %{
      event_id: nil,
      tag_id: nil
    }

    attrs = Map.merge(defaults, attrs)

    %EventTag{}
    |> struct(attrs)
    |> Repo.insert!()
  end

  def associate_event_with_tags(event, tags) when is_list(tags) do
    Enum.each(tags, fn tag ->
      insert_event_tag(%{event_id: event.id, tag_id: tag.id})
    end)

    event
  end

  @doc """
  Seeds a small dataset:

    - orgs: Beatz, Donutz
    - events with mixed statuses, times, and org associations
    - tags: music, workshop, live, outdoor, family
    - event tags: various associations between events and tags
  """
  def setup_sample_events do
    beatz = insert_organization(%{name: "Beatz"})
    donutz = insert_organization(%{name: "Donutz"})

    music_tag = insert_tag(%{name: "music"})
    workshop_tag = insert_tag(%{name: "workshop"})
    live_tag = insert_tag(%{name: "live"})
    outdoor_tag = insert_tag(%{name: "outdoor"})
    family_tag = insert_tag(%{name: "family"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    e1 =
      insert_event(%{
        name: "Typhoon Works Event",
        description: "some description",
        status: "draft",
        organization_id: beatz.id,
        time_start: DateTime.add(now, 24 * 3600, :second),
        time_end: DateTime.add(now, 2 * 24 * 3600, :second)
      })
      |> associate_event_with_tags([music_tag, workshop_tag])

    e2 =
      insert_event(%{
        name: "Old School Beats",
        description: "Event hosted by Typhoon Works!",
        status: "building",
        organization_id: donutz.id,
        time_start: DateTime.add(now, 5 * 24 * 3600, :second),
        time_end: DateTime.add(now, 6 * 24 * 3600, :second)
      })
      |> associate_event_with_tags([music_tag, live_tag, outdoor_tag])

    e3 =
      insert_event(%{
        name: "The ABC event",
        description: "another description",
        status: "live",
        organization_id: beatz.id,
        time_start: DateTime.add(now, 5 * 24 * 3600, :second),
        time_end: DateTime.add(now, 6 * 24 * 3600, :second)
      })
      |> associate_event_with_tags([family_tag, outdoor_tag])

    e4 =
      insert_event(%{
        name: "O'Connor Show",
        description: "some desc",
        status: "live",
        organization_id: donutz.id,
        time_start: DateTime.add(now, -2 * 24 * 3600, :second),
        time_end: DateTime.add(now, 6 * 24 * 3600, :second)
      })
      |> associate_event_with_tags([live_tag, music_tag, family_tag])

    %{
      orgs: %{beatz: beatz, donutz: donutz},
      events: %{e1: e1, e2: e2, e3: e3, e4: e4},
      tags: %{
        music: music_tag,
        workshop: workshop_tag,
        live: live_tag,
        outdoor: outdoor_tag,
        family: family_tag
      }
    }
  end

  @doc """
  Convenience seed for full-text tests.
  """
  def setup_full_text_examples do
    e1 = insert_event(%{name: "The ABC event", description: "some description"})
    e2 = insert_event(%{name: "XYZ", description: "another description"})
    e3 = insert_event(%{name: "XYZ", description: "An abc event"})
    e4 = insert_event(%{name: "O'Connor Show", description: "some desc"})
    %{e1: e1, e2: e2, e3: e3, e4: e4}
  end
end
