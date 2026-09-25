defmodule PhoenixKitStaff.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint. Real layouts live in
  the host app and the phoenix_kit core — these just wrap LiveView
  content in an HTML shell so Phoenix.LiveViewTest can render it.

  `app/1` renders flash divs so smoke tests can assert flash content
  via `render(view) =~ "Saved."` after click events. Without these,
  Phoenix.Flash.get/2 returns the message but it never reaches the
  rendered HTML, and tests fall back to "process alive" tautologies.

  It also renders the `page_title` / `page_subtitle` / `page_section` /
  `page_crumbs` / `page_action` assigns that core's admin layout shows in its breadcrumb
  bar, because the Staff LiveViews no longer render their own headers.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div id="test-flashes">
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" data-flash-kind="info">
        {msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" data-flash-kind="error">
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :warning)}
        id="flash-warning"
        data-flash-kind="warning"
      >
        {msg}
      </div>
    </div>
    <%!-- Stand-in for core's admin breadcrumb bar. Since 0.8.3 every Staff
         page pushes its heading into `page_title` / `page_subtitle` /
         `page_section` / `page_action` instead of rendering an in-body
         header (see `LayoutWrapper` in core), so the test harness has to
         render those assigns somewhere for `html =~` / `has_element?`
         assertions to see them. `assigns[:…]` because a page that sets
         none of them must still render. --%>
    <div :if={assigns[:page_title]} id="test-page-title">{@page_title}</div>
    <div :if={assigns[:page_subtitle]} id="test-page-subtitle">{@page_subtitle}</div>
    <a :if={assigns[:page_section]} id="test-page-section" href={assigns[:page_section_path]}>
      {@page_section}
    </a>
    <nav :if={assigns[:page_crumbs]} id="test-page-crumbs">
      <a :for={crumb <- @page_crumbs} href={crumb[:path] || crumb[:patch]}>{crumb.label}</a>
    </nav>
    <a :if={assigns[:page_action]} id="test-page-action" href={@page_action[:navigate]}>
      {@page_action[:label]}
    </a>
    {@inner_content}
    """
  end

  # Phoenix's error pipeline will try to render "<status>.html" from the
  # layouts module if a LiveView raises during mount. Forward everything
  # to a single generic template so tests get a readable error instead
  # of a `no template defined` crash.
  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
