defmodule PhoenixKitStaff.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint.

  Production runs LiveViews inside `live_session :phoenix_kit_admin`,
  which is configured by core `phoenix_kit` to populate
  `socket.assigns[:phoenix_kit_current_scope]` and
  `socket.assigns[:phoenix_kit_current_user]` from the host app's
  authentication. Our test endpoint doesn't load core's hooks, so this
  module replicates the same effect by pulling scope data from the
  test session.

  Tests set scope via `LiveCase.put_test_scope/2` (which calls
  `Plug.Test.init_test_session/2`); the `:assign_scope` hook below
  reads it back and mirrors it onto socket assigns.
  """

  alias PhoenixKit.Modules.Languages

  import Phoenix.Component, only: [assign: 3]

  @doc """
  `on_mount` callback. Reads `"phoenix_kit_test_scope"` from session and
  assigns `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`
  onto the socket. No-op when session has no scope (LiveView mounts
  with the same nil-scope state production sees for logged-out users).
  """
  def on_mount(:assign_scope, _params, session, socket) do
    # Production's admin live_session puts the request locale on the process
    # (so `current_content_lang/0` resolves it during render). The test
    # endpoint doesn't, so mirror it from an optional session key — no-op
    # when absent, keeping every existing test's default-locale behaviour.
    maybe_put_locale(session)

    case Map.get(session, "phoenix_kit_test_scope") do
      nil ->
        {:cont, socket}

      %{user: user} = scope ->
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        {:cont, socket}
    end
  end

  # Both halves of what production's locale hook does for a `/fr/…` URL:
  # Gettext for the copy, the request locale for the page language
  # (`mount_multilang(open_on: :viewing_language)` reads only that).
  defp maybe_put_locale(%{"phoenix_kit_test_locale" => locale}) when is_binary(locale) do
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Languages.put_request_locale(locale)
  end

  defp maybe_put_locale(_session), do: :ok
end
