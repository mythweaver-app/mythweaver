defmodule MythweaverWeb.ColocatedScopedCSSTest do
  use ExUnit.Case, async: true

  alias MythweaverWeb.ColocatedScopedCSS

  describe "transform/4" do
    test "transforms CSS with default (exclusive) lower bound" do
      css = ".my-class { color: red; }"
      attrs = %{}
      meta = %{module: MyApp.MyComponent, line: 42, file: "test.ex"}

      assert {:ok, transformed_css, directives} =
               ColocatedScopedCSS.transform("style", attrs, css, meta)

      # Should wrap in @scope
      assert transformed_css =~ "@scope"
      assert transformed_css =~ "[phx-css-"
      assert transformed_css =~ "to ([phx-r])"
      assert transformed_css =~ ".my-class { color: red; }"

      # Should return root_tag_attribute directive
      assert [root_tag_attribute: {attr_name, true}] = directives
      assert attr_name =~ ~r/^phx-css-[a-z0-9]+$/
    end

    test "transforms CSS with inclusive lower bound" do
      css = ".my-class { color: blue; }"
      attrs = %{"lower-bound" => "inclusive"}
      meta = %{module: MyApp.MyComponent, line: 42, file: "test.ex"}

      assert {:ok, transformed_css, directives} =
               ColocatedScopedCSS.transform("style", attrs, css, meta)

      # Should wrap in @scope with inclusive lower bound
      assert transformed_css =~ "@scope"
      assert transformed_css =~ "to ([phx-r] > *)"
      assert transformed_css =~ ".my-class { color: blue; }"

      # Should return root_tag_attribute directive
      assert [root_tag_attribute: {attr_name, true}] = directives
      assert attr_name =~ ~r/^phx-css-[a-z0-9]+$/
    end

    test "transforms CSS with none lower bound" do
      css = ".my-class { color: green; }"
      attrs = %{"lower-bound" => "none"}
      meta = %{module: MyApp.MyComponent, line: 42, file: "test.ex"}

      assert {:ok, transformed_css, directives} =
               ColocatedScopedCSS.transform("style", attrs, css, meta)

      # Should wrap in @scope with no lower bound
      assert transformed_css =~ "@scope"
      assert transformed_css =~ "[phx-css-"
      refute transformed_css =~ "to ("
      assert transformed_css =~ ".my-class"

      # Should return root_tag_attribute directive
      assert [root_tag_attribute: {attr_name, true}] = directives
      assert attr_name =~ ~r/^phx-css-[a-z0-9]+$/
    end

    test "generates consistent hash for same content" do
      css = ".test { color: green; }"
      attrs = %{}
      meta = %{module: MyApp.MyComponent, line: 10, file: "test.ex"}

      {:ok, css1, [{:root_tag_attribute, {scope1, _}}]} =
        ColocatedScopedCSS.transform("style", attrs, css, meta)

      {:ok, css2, [{:root_tag_attribute, {scope2, _}}]} =
        ColocatedScopedCSS.transform("style", attrs, css, meta)

      # Same input should produce same scope
      assert scope1 == scope2
      assert css1 == css2
    end

    test "generates different hashes for different content" do
      attrs = %{}
      meta = %{module: MyApp.MyComponent, line: 10, file: "test.ex"}

      {:ok, _, [{:root_tag_attribute, {scope1, _}}]} =
        ColocatedScopedCSS.transform("style", attrs, ".class1 { color: red; }", meta)

      {:ok, _, [{:root_tag_attribute, {scope2, _}}]} =
        ColocatedScopedCSS.transform("style", attrs, ".class2 { color: blue; }", meta)

      # Different CSS should produce different scopes
      assert scope1 != scope2
    end

    test "raises error for invalid lower-bound value" do
      css = ".my-class { color: red; }"
      attrs = %{"lower-bound" => "invalid"}
      meta = %{module: MyApp.MyComponent, line: 42, file: "test.ex"}

      assert_raise ArgumentError, ~r/expected "inclusive", "exclusive", or "none"/, fn ->
        ColocatedScopedCSS.transform("style", attrs, css, meta)
      end
    end

    test "allows exclusive lower-bound value" do
      css = ".my-class { color: red; }"
      attrs = %{"lower-bound" => "exclusive"}
      meta = %{module: MyApp.MyComponent, line: 42, file: "test.ex"}

      assert {:ok, transformed_css, _} = ColocatedScopedCSS.transform("style", attrs, css, meta)
      assert transformed_css =~ "to ([phx-r])"
      refute transformed_css =~ "to ([phx-r] > *)"
    end

    test "ignores unknown attributes" do
      css = ".my-class { color: red; }"
      attrs = %{"data-foo" => "bar", "other-attr" => "value"}
      meta = %{module: MyApp.MyComponent, line: 42, file: "test.ex"}

      # Should not raise error for unknown attributes
      assert {:ok, _, _} = ColocatedScopedCSS.transform("style", attrs, css, meta)
    end
  end
end
