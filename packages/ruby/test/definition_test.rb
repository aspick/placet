# frozen_string_literal: true

require_relative "test_helper"

# DSL・意味的検証・正規形の入出力のユニットテスト
class DefinitionTest < Minitest::Test
  def setup = Placet.reset!
  def teardown = Placet.reset!

  def test_dsl_compiles_to_canonical_form
    Placet.define do
      policy "post-editor", attach_to: "role:editor" do
        allow "post:create", "post:update"
        deny "post:delete"
      end
      attach "role:chief", "post-editor"
    end

    assert_equal(
      {
        "version" => 1,
        "policies" => [
          { "name" => "post-editor",
            "statements" => [
              { "effect" => "allow", "actions" => ["post:create", "post:update"] },
              { "effect" => "deny", "actions" => ["post:delete"] }
            ] }
        ],
        "attachments" => [
          { "principal" => "role:editor", "policies" => ["post-editor"] },
          { "principal" => "role:chief", "policies" => ["post-editor"] }
        ]
      },
      Placet.export
    )
  end

  def test_export_round_trips_through_from_canonical
    Placet.define do
      policy "reader", attach_to: "role:member" do
        allow "post:view"
      end
    end
    definition = Placet::Definition.from_canonical(Placet.export)
    assert_equal Placet.export, definition.to_canonical
  end

  def test_duplicate_policy_name_is_rejected
    assert_raises(Placet::DefinitionError) do
      Placet.define do
        policy("dup") { allow "post:view" }
        policy("dup") { allow "post:update" }
      end
    end
  end

  def test_unresolved_policy_reference_is_rejected
    assert_raises(Placet::DefinitionError) do
      Placet.define { attach "role:member", "missing" }
    end
  end

  def test_invalid_action_pattern_is_rejected
    assert_raises(Placet::DefinitionError) do
      Placet.define { policy("bad") { allow "Post::VIEW" } }
    end
  end

  def test_principal_wildcard_is_rejected
    assert_raises(Placet::DefinitionError) do
      Placet.define do
        policy("p", attach_to: "tenant:*") { allow "post:view" }
      end
    end
  end

  def test_action_registry_rejects_unknown_actions_in_policies
    assert_raises(Placet::DefinitionError) do
      Placet.define do
        actions "post", %w[view create]
        policy("typo") { allow "post:veiw" }
      end
    end
  end

  def test_action_registry_rejects_unknown_actions_in_decide
    Placet.define do
      actions "post", %w[view]
      policy("reader", attach_to: "role:member") { allow "post:view" }
    end
    Placet.resolver { |_user| ["role:member"] }

    assert_raises(Placet::Error) { Placet.decide(:user, "post:veiw") }
  end

  def test_action_registry_rejects_unknown_actions_in_scope_plan
    Placet.define do
      actions "post", %w[view]
      policy("reader", attach_to: "role:member") { allow "post:view" }
    end

    assert_raises(Placet::Error) do
      Placet.engine.scope_plan(["role:member"], "post:veiw", relations: [])
    end
  end

  def test_relation_requires_check_and_scope_pair
    model = Class.new
    assert_raises(Placet::DefinitionError) do
      Placet.relation(:owner, resource: model) do
        check { |_u, _r| true }
        # scope が無い
      end
    end
  end
end
