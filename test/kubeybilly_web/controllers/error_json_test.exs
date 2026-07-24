defmodule KubeybillyWeb.ErrorJSONTest do
  use KubeybillyWeb.ConnCase, async: true

  @moduletag :integration

  test "renders 404" do
    assert KubeybillyWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert KubeybillyWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
