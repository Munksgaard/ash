# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Regression test: actor must propagate through embedded resource
# casting so that `relate_actor` on nested embedded resources works.
#
# With `config :ash, :include_embedded_source_by_default?, false`,
# setting `include_source?: true` on the union types should be
# sufficient to opt-in to source propagation. However, the union's
# `cast_input` passes `config_constraints` (variant-level constraints)
# to the inner embedded type's `include_source`, and those constraints
# don't include `include_source?`. The embedded type then falls back
# to `@include_source_by_default` (compiled as `false`), dropping the
# source changeset and losing the actor.

defmodule Ash.Test.Resource.Changes.RelateActorEmbeddedTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Ash.Test.Domain, as: Domain

  # --- Actor resource (the "user") ----------------------------------------

  defmodule User do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: :*]
    end
  end

  # --- Deepest embedded: uses relate_actor --------------------------------

  defmodule UserAuthor do
    use Ash.Resource,
      domain: Domain,
      data_layer: :embedded

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        change relate_actor(:user)
      end
    end

    relationships do
      belongs_to :user, User do
        allow_nil? false
        attribute_type :uuid
      end
    end
  end

  # --- Union wrapping UserAuthor ------------------------------------------
  # include_source?: true opts in to source propagation, but the bug
  # prevents this from reaching the inner embedded type.

  defmodule AuthorUnion do
    use Ash.Type.NewType,
      subtype_of: :union,
      constraints: [
        include_source?: true,
        storage: :map_with_tag,
        types: [
          user_author: [
            type: UserAuthor,
            tag: :__type__,
            tag_value: "user_author"
          ]
        ]
      ]
  end

  # --- Embedded resource containing the union author ----------------------

  defmodule CommentData do
    use Ash.Resource,
      domain: Domain,
      data_layer: :embedded

    actions do
      defaults [:read, create: [:text, :author]]
    end

    attributes do
      attribute :text, :string, allow_nil?: false, public?: true
      attribute :author, AuthorUnion, allow_nil?: false, public?: true
    end
  end

  # --- Top-level union wrapping CommentData -------------------------------

  defmodule EntryData do
    use Ash.Type.NewType,
      subtype_of: :union,
      constraints: [
        include_source?: true,
        storage: :map_with_tag,
        types: [
          comment: [
            type: CommentData,
            tag: :__type__,
            tag_value: "comment"
          ]
        ]
      ]
  end

  # --- Child resource (has the embedded data attribute) -------------------

  defmodule Child do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :data, EntryData, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, create: [:data, :parent_id]]
    end

    relationships do
      belongs_to :parent,
                 Ash.Test.Resource.Changes.RelateActorEmbeddedTest.Parent do
        allow_nil? false
        public? true
      end
    end
  end

  # --- Parent resource (manages children via relationship) ----------------

  defmodule Parent do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id

      attribute :name, :string do
        public? true
      end
    end

    actions do
      defaults [:read, create: [:name]]

      update :add_child do
        require_atomic? false
        argument :children, {:array, :map}
        change manage_relationship(:children, type: :create)
      end
    end

    relationships do
      has_many :children, Child do
        destination_attribute :parent_id
      end
    end
  end

  # --- Tests --------------------------------------------------------------

  test "relate_actor propagates through manage_relationship into nested embedded union" do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()

    parent =
      Parent
      |> Ash.Changeset.for_create(:create, %{name: "parent"})
      |> Ash.create!()

    child_data = [
      %{
        data: %{
          __type__: "comment",
          text: "hello",
          author: %{__type__: "user_author"}
        }
      }
    ]

    updated =
      parent
      |> Ash.Changeset.for_update(:add_child, %{children: child_data}, actor: user)
      |> Ash.update!()

    updated = Ash.load!(updated, :children)

    assert [child] = updated.children
    assert child.data.value.text == "hello"
    assert child.data.value.author.type == :user_author
    assert child.data.value.author.value.user_id == user.id
  end

  test "relate_actor propagates through direct create into nested embedded union" do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()

    parent =
      Parent
      |> Ash.Changeset.for_create(:create, %{name: "parent"})
      |> Ash.create!()

    child =
      Child
      |> Ash.Changeset.for_create(
        :create,
        %{
          parent_id: parent.id,
          data: %{__type__: "comment", text: "direct", author: %{__type__: "user_author"}}
        },
        actor: user
      )
      |> Ash.create!()

    assert child.data.value.text == "direct"
    assert child.data.value.author.type == :user_author
    assert child.data.value.author.value.user_id == user.id
  end
end
