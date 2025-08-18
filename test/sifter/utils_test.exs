defmodule Sifter.UtilsTest do
  use ExUnit.Case, async: true
  alias Sifter.Utils

  test "simple camelCase" do
    assert Utils.to_snake_case("firstName") == "first_name"
  end

  test "dot notation + camelCase per segment" do
    assert Utils.to_snake_case("userProfile.firstName") == "user_profile.first_name"
  end

  test "digits and hyphen" do
    assert Utils.to_snake_case("userID2-part") == "user_id2_part"
  end

  test "already snake" do
    assert Utils.to_snake_case("user.first_name") == "user.first_name"
  end

  test "keyword prefixed identifiers" do
    assert Utils.to_snake_case("NOTstatus") == "notstatus"
    assert Utils.to_snake_case("ORstatus") == "orstatus"
    assert Utils.to_snake_case("ANDoperator") == "andoperator"
  end

  test "keyword prefixed identifiers with more capitals" do
    assert Utils.to_snake_case("NOTAPI") == "notapi"
    assert Utils.to_snake_case("ORXML") == "orxml"
  end

  test "standalone keywords" do
    assert Utils.to_snake_case("NOT") == "not"
    assert Utils.to_snake_case("OR") == "or"
    assert Utils.to_snake_case("AND") == "and"
  end
end
