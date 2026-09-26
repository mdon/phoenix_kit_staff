defmodule PhoenixKitStaff.MixProject do
  use Mix.Project

  @version "0.8.6"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_staff"

  def project do
    [
      app: :phoenix_kit_staff,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_ignore_filters: [~r"/support/"],
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitStaff\.Test\./,
          PhoenixKitStaff.DataCase,
          PhoenixKitStaff.LiveCase,
          PhoenixKitStaff.ActivityLogAssertions
        ]
      ],
      description: "Staff module for PhoenixKit — departments, teams, and people.",
      package: package(),
      dialyzer: [
        plt_add_apps: [:phoenix_kit, :phoenix_kit_comments],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      name: "PhoenixKitStaff",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :phoenix_kit, :phoenix_kit_comments]]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, "test.reset": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitStaff.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitStaff.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # The floor is 2.38.0: the module runs on core's shared toolkits —
      # `PhoenixKitWeb.Actor`, `PhoenixKit.Activity.log/3`,
      # `Storage.ResourceFolders`, the reorganizer's `ResourceSource`,
      # `Utils.Format` and `mount_multilang(open_on:)` — all first shipped
      # there, and none is feature-detected, so a lower core fails to compile.
      # Patch-precise floor in the compound form, so the ceiling stays open
      # through every later 2.x minor (a three-segment `~> 2.38.0` would pin
      # one minor; see test/core_pin_conformance_test.exs).
      pk_dep(:phoenix_kit, ">= 2.38.0 and < 3.0.0"),
      # Hard dep: PersonShowLive embeds the comment thread (Comments tab) and
      # `use PhoenixKitComments.Embed` for the composer's Leaf-event forwarding,
      # both compile-time. `Embed` arrived *mid*-0.2.x — in 0.2.6 — so `~> 0.2`
      # was the same defect the core pin above fixes: it admits 0.2.0–0.2.5,
      # where the module doesn't exist and the `use` site fails to compile.
      pk_dep(:phoenix_kit_comments, "~> 0.3"),
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      # Own Gettext backend for staff-specific (domain) UI strings; generic
      # strings stay on core's `PhoenixKitWeb.Gettext`. `mix gettext.extract`
      # / `gettext.merge` run against this app's `priv/gettext`.
      {:gettext, "~> 0.26 or ~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # `Phoenix.LiveViewTest` parses HTML via `lazy_html` for `element/2`,
      # `render(view) =~ "..."`, etc. Test-only.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [main: "PhoenixKitStaff", source_ref: @version]
  end
end
