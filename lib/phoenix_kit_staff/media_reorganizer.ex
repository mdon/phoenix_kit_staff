defmodule PhoenixKitStaff.MediaReorganizer do
  @moduledoc """
  Staff's media-reorganizer plan source: each live person's
  `staff-person-<uuid>` folder (its `Images` subfolder moves with it),
  planned by core's `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`,
  which applies the `Reorganizer.Source` contract.

  What is staff's own: a person is live until trashed; the parent hook
  receives the person's uuid as its subject; a person stores no folder
  pointer (folders are found by name), so a taken target is reported
  rather than renamed, and there are no pending-upload folders.
  """

  import Ecto.Query, only: [where: 3]

  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource
  alias PhoenixKitStaff.Schemas.Person

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` is passed through."
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

  defp spec do
    %{
      source: "staff",
      app: :phoenix_kit_staff,
      # Folders are always `staff-person-<uuid>`: uploads never ask the
      # folder-name hook, so no plan may propose a host name.
      name_hook: false,
      kinds: [
        %{kind: :person, schema: Person, prefix: "staff-person-", subject: :uuid, live: &live/1}
      ]
    }
  end

  defp live(query), do: where(query, [p], p.status != "trashed")
end
