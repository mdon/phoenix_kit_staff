defmodule PhoenixKitStaff.Web.HeaderTrailTest do
  @moduledoc """
  Pins every staff page's admin-header trail to core's shape
  (`phoenix_kit/dev_docs/guides/2026-09-25-admin-header-trail.md`):
  the Overview is the landing page (title `Staff`, no section); every page
  under it carries `Staff` as the section, the list it belongs to as a crumb,
  a record page adds nothing but the record's name as its title, and an edit
  page adds the record as a linked crumb and is titled `Edit`. The test
  layout renders the four assigns as `#test-page-*` elements.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Paths

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  defp title(view), do: view |> element("#test-page-title") |> render() |> text()

  defp section(view) do
    if has_element?(view, "#test-page-section") do
      html = view |> element("#test-page-section") |> render()
      {text(html), attr(html, "href")}
    end
  end

  # A page that sets no `page_crumbs` renders no nav at all.
  defp crumbs(view) do
    if has_element?(view, "#test-page-crumbs") do
      html = view |> element("#test-page-crumbs") |> render()

      ~r/<a href="([^"]*)">([^<]*)<\/a>/
      |> Regex.scan(html)
      |> Enum.map(fn [_, href, label] -> {String.trim(label), href} end)
    else
      []
    end
  end

  # The rendered elements hold one text node each, so a regex is enough (no
  # HTML parser in this suite's deps).
  defp text(html),
    do: ~r/>([^<]*)</ |> Regex.run(html, capture: :all_but_first) |> hd() |> String.trim()

  defp attr(html, name),
    do: ~r/#{name}="([^"]*)"/ |> Regex.run(html, capture: :all_but_first) |> hd()

  defp staff, do: {"Staff", Paths.index()}

  test "the Overview is the landing page: the module is the title, no section", %{conn: conn} do
    {:ok, view, _} = live(conn, Paths.index())
    assert title(view) == "Staff"
    assert section(view) == nil
    refute has_element?(view, "#test-page-crumbs a")
  end

  test "list pages carry the module as their section", %{conn: conn} do
    for {path, expected} <- [
          {Paths.departments(), "Departments"},
          {Paths.teams(), "Teams"},
          {Paths.people(), "Staff"},
          {Paths.skills(), "Skills"}
        ] do
      {:ok, view, _} = live(conn, path)
      assert section(view) == staff()
      assert crumbs(view) == []
      assert title(view) == expected
    end
  end

  test "record pages: the list is the crumb, the record's name is the title", %{conn: conn} do
    dept = fixture_department(%{"name" => "Trail dept #{System.unique_integer([:positive])}"})
    team = fixture_team(%{"department_uuid" => dept.uuid, "name" => "Trail team"})
    person = fixture_person(%{"name" => "Trail Person"})
    skill = fixture_skill(%{"name" => "Trail skill #{System.unique_integer([:positive])}"})

    for {path, list, expected} <- [
          {Paths.department(dept.uuid), {"Departments", Paths.departments()}, dept.name},
          {Paths.team(team.uuid), {"Teams", Paths.teams()}, team.name},
          {Paths.person(person.uuid), {"Staff", Paths.people()}, "Trail Person"},
          {Paths.skill(skill.uuid), {"Skills", Paths.skills()}, skill.name}
        ] do
      {:ok, view, _} = live(conn, path)
      assert section(view) == staff()
      assert crumbs(view) == [list]
      assert title(view) == expected
    end
  end

  test "new pages: the list is the crumb, the title names the page", %{conn: conn} do
    for {path, list, expected} <- [
          {Paths.new_department(), {"Departments", Paths.departments()}, "New department"},
          {Paths.new_team(), {"Teams", Paths.teams()}, "New team"},
          {Paths.new_person(), {"Staff", Paths.people()}, "New staff"},
          {Paths.new_skill(), {"Skills", Paths.skills()}, "New skill"}
        ] do
      {:ok, view, _} = live(conn, path)
      assert section(view) == staff()
      assert crumbs(view) == [list]
      assert title(view) == expected
    end
  end

  test "edit pages: the record is a crumb linking to its page, the title is Edit", %{conn: conn} do
    dept = fixture_department(%{"name" => "Trail dept #{System.unique_integer([:positive])}"})
    team = fixture_team(%{"department_uuid" => dept.uuid, "name" => "Trail team"})
    person = fixture_person(%{"name" => "Trail Person"})
    skill = fixture_skill(%{"name" => "Trail skill #{System.unique_integer([:positive])}"})

    for {path, list, record} <- [
          {Paths.edit_department(dept.uuid), {"Departments", Paths.departments()},
           {dept.name, Paths.department(dept.uuid)}},
          {Paths.edit_team(team.uuid), {"Teams", Paths.teams()},
           {team.name, Paths.team(team.uuid)}},
          {Paths.edit_person(person.uuid), {"Staff", Paths.people()},
           {"Trail Person", Paths.person(person.uuid)}},
          {Paths.edit_skill(skill.uuid), {"Skills", Paths.skills()},
           {skill.name, Paths.skill(skill.uuid)}}
        ] do
      {:ok, view, _} = live(conn, path)
      assert section(view) == staff()
      assert crumbs(view) == [list, record]
      assert title(view) == "Edit"
    end
  end

  test "no title carries its own trail", %{conn: conn} do
    dept = fixture_department()

    for path <- [
          Paths.index(),
          Paths.departments(),
          Paths.department(dept.uuid),
          Paths.edit_department(dept.uuid)
        ] do
      {:ok, view, _} = live(conn, path)
      refute title(view) =~ ~r/ — | - | \/ /
    end
  end
end
