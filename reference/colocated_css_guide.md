# Colocated CSS Guide

This project supports both **global** and **scoped** colocated CSS for Phoenix LiveView components.

> **TailwindCSS is banned.** Do not use tailwind utility classes, `@apply`, tailwind directives, or any tailwind config anywhere in this project. All styling **must** be authored as colocated CSS (preferred) or, only when unavoidable, global `app.css`. The same colocated-first rule applies to client-side JS: prefer colocated hooks over external `assets/js/` files. See the JS/CSS guidelines in `AGENTS.md`.

## Priority Order

Reach for styling in this order — stop at the first that fits:

1. **Scoped colocated CSS** (`MythweaverWeb.ColocatedScopedCSS`) — the default for component-specific styles.
2. **Global colocated CSS** (`MythweaverWeb.ColocatedCSS`) — only for genuinely reusable utilities/base styles.
3. **Global `app.css`** — only if necessary.
4. **Inline `style="..."`** — avoid unless absolutely necessary (e.g. dynamic values computed from Elixir).

## Modules

### `MythweaverWeb.ColocatedCSS` - Global CSS
Use this for utility classes or styles that should apply globally across the application.

**Example:**
```elixir
defmodule MyApp.ButtonComponent do
  use Phoenix.Component

  def button(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      .btn-utility { 
        padding: 0.5rem 1rem;
        border-radius: 0.25rem;
      }
    </style>
    
    <button class="btn-utility"><%= render_slot(@inner_block) %></button>
    """
  end
end
```

The CSS will be extracted globally and available to all components.

---

### `MythweaverWeb.ColocatedScopedCSS` - Scoped CSS
Use this for component-specific styles that should **only** apply within the component's boundaries. This uses CSS `@scope` rules to prevent style leakage.

**Example:**
```elixir
defmodule MyApp.CardComponent do
  use Phoenix.Component

  def card(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      .card-title { 
        font-size: 1.5rem;
        font-weight: bold;
      }
      .card-content {
        padding: 1rem;
      }
    </style>
    
    <div class="card">
      <h3 class="card-title"><%= @title %></h3>
      <div class="card-content">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end
end
```

The `.card-title` and `.card-content` styles will **only** apply within this component, not to any nested components or parent elements.

---

## Scoped CSS Lower Bound Options

By default, scoped CSS uses an **exclusive** lower bound, which stops at nested component boundaries.

### Exclusive (default)
```heex
<style :type={MythweaverWeb.ColocatedScopedCSS}>
  .my-class { color: red; }
</style>
```

This generates:
```css
@scope ([phx-css-abc123]) to ([phx-r]) {
  .my-class { color: red; }
}
```

Styles stop at nested component roots (elements with `phx-r` attribute).

### Inclusive
```heex
<style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="inclusive">
  .my-class { color: red; }
</style>
```

This generates:
```css
@scope ([phx-css-abc123]) to ([phx-r] > *) {
  .my-class { color: red; }
}
```

Styles reach a nested component's root element (`[phx-r]`) but nothing below it.

### None (no lower bound)
```heex
<style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
  .my-class { color: red; }
</style>
```

This generates:
```css
@scope ([phx-css-abc123]) {
  .my-class { color: red; }
}
```

With no lower bound, styles apply to the element and **all** its descendants,
crossing nested component boundaries (elements with `phx-r`). This defeats the
encapsulation that scoping normally provides, so reserve it for deliberate
parent-page overrides that must reach inside function components like
`<.form>`/`<.input>`.

---

## How Scoped CSS Works

1. **Unique Scope ID**: Each `<style>` block gets a hash-based scope identifier (e.g., `phx-css-abc123`)
2. **Attribute Injection**: The scope ID is added as an attribute to all root tags in the template
3. **CSS @scope Rule**: Styles are wrapped in a `@scope` rule with:
   - **Upper bound**: The scope ID attribute (start applying here)
   - **Lower bound**: The `phx-r` attribute (stop applying here)
4. **Automatic Boundary Detection**: LiveView adds `phx-r` to all component root tags

### Example Transformation

**Input:**
```heex
<div>
  <style :type={MythweaverWeb.ColocatedScopedCSS}>
    .title { color: blue; }
  </style>
  
  <h1 class="title">Hello</h1>
  
  <.nested_component>
    <p class="title">World</p>
  </.nested_component>
</div>
```

**Output HTML:**
```html
<div phx-css-abc123>
  <h1 class="title">Hello</h1>  <!-- styled -->
  
  <div phx-r>  <!-- nested component root -->
    <p class="title">World</p>  <!-- NOT styled (outside scope) -->
  </div>
</div>
```

**Generated CSS:**
```css
@scope ([phx-css-abc123]) to ([phx-r]) {
  .title { color: blue; }
}
```

---

## When to Use Each

### Use `MythweaverWeb.ColocatedCSS` (Global) when:
- Creating utility classes meant for reuse
- Defining base styles or resets
- Working with third-party component styling

### Use `MythweaverWeb.ColocatedScopedCSS` (Scoped) when:
- Building self-contained components
- Preventing style conflicts between components
- Creating component-specific layout rules
- You want true CSS encapsulation without BEM or similar conventions

---

## Breakpoints and Drawers

Breakpoint and input queries use the saved custom media in `assets/css/media.css`, in `assets/css`
and colocated blocks alike, and never their literals:

| Name | Query | Use |
|---|---|---|
| `--phone` | `(max-width: 50rem)` | phones, and a foldable's inner screen |
| `--tablet` | `(max-width: 64rem)` | tablets and phones |
| `--touch` | `(hover: none)` | replacing hover-only affordances |
| `--coarse` | `(pointer: coarse)` | 44px hit areas (`var(--touch-target)`) |

```css
@media (--phone) { div:scope { grid-template-columns: minmax(0, 1fr); } }
@media (--phone), (--coarse) { .row { flex-wrap: wrap; } }
```

Bun's CSS bundler leaves `@custom-media` alone; `assets/build.ts` resolves it with LightningCSS
afterwards, and an undefined name fails the build.

A side rail or toolbar that must leave the screen below a breakpoint becomes a drawer
(`MythweaverWeb.CoreComponents.Drawer`): the panel element itself gets `popover`, an id and
`drawer drawer--start|end|bottom drawer--phone|tablet`, and a `<.drawer_toggle for=…>` opens it.
Above the breakpoint it stays an ordinary in-flow panel. Don't build another slide-over.

---

## Browser Support

CSS `@scope` is supported in:
- Chrome/Edge 118+
- Safari 17.4+
- Firefox 128+

For older browsers, use global CSS with manual scoping via class naming conventions (BEM, etc.).

---

## Configuration

The scoped CSS implementation requires the following configuration in `config/config.exs`:

```elixir
config :phoenix_live_view, root_tag_attribute: "phx-r"
```

This is already configured in this project.

---

## Tips

1. **Colocated CSS for Complex Components**: Use colocated CSS when a component needs non-trivial custom styles.
2. **Scope by Default**: Start with `MythweaverWeb.ColocatedScopedCSS`; promote a rule to global `MythweaverWeb.ColocatedCSS` only when it is genuinely reused across components.
3. **Never Tailwind**: If you're reaching for a utility class, write the equivalent colocated CSS instead.
4. **Inspect in DevTools**: Use browser DevTools to see the generated `@scope` rules and scope attributes.

---

## Examples in This Project

Client-side behavior follows the same colocated-first rule: prefer a colocated JS hook (`<script :type={Phoenix.LiveView.ColocatedHook} name=".MyHook">`) inside the template over an external `assets/js/` hook. The following demonstrate colocated JS (same pattern, JS instead of CSS):
- `ZoomControl` - `lib/mythweaver_web/components/aether/zoom_control.ex`
- `MinimapControl` - `lib/mythweaver_web/components/aether/minimap.ex`
- `DiagramContainer` - `lib/mythweaver_web/live/main_live/index.ex`

To see colocated CSS in action, add a `<style>` tag to any of these components using either `MythweaverWeb.ColocatedCSS` or `MythweaverWeb.ColocatedScopedCSS`.
