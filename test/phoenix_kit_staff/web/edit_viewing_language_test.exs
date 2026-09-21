defmodule PhoenixKitStaff.Web.EditViewingLanguageTest do
  @moduledoc """
  The department, team, person and skill forms open an EDIT on the language
  tab of the language the admin is viewing the page in; a new record starts
  on the main language, which holds its required fields.
  """
  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKit.Modules.Languages

  @base "/en/admin/staff"

  setup %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("fr-FR")
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, "en") end)

    department = fixture_department()

    %{
      conn: conn |> put_test_scope(fake_scope()) |> put_test_locale("fr-FR"),
      department: department,
      team: fixture_team(%{"department_uuid" => department.uuid}),
      person: fixture_person(),
      skill: fixture_skill()
    }
  end

  defp open_lang(view), do: :sys.get_state(view.pid).socket.assigns.current_lang

  test "viewed in French, the edit forms open on the French tab", ctx do
    for path <- [
          "#{@base}/departments/#{ctx.department.uuid}/edit",
          "#{@base}/teams/#{ctx.team.uuid}/edit",
          "#{@base}/people/#{ctx.person.uuid}/edit",
          "#{@base}/skills/#{ctx.skill.uuid}/edit"
        ] do
      {:ok, view, _html} = live(ctx.conn, path)
      assert open_lang(view) == "fr-FR", path
    end
  end

  test "viewed in French, a new record starts on the main tab", ctx do
    for resource <- ~w(departments teams people skills) do
      {:ok, view, _html} = live(ctx.conn, "#{@base}/#{resource}/new")
      assert open_lang(view) == "en-US", resource
    end
  end
end
