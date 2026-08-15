defmodule Mix.Tasks.PhoenixBunAssets.InstallTest do
  use ExUnit.Case
  import Igniter.Test

  # A minimal Phoenix-shaped project: an endpoint module plus dev/config files.
  # This avoids depending on the `phx_new` archive that `phx_test_project/0` needs.
  defp installed(argv \\ []) do
    test_project(
      app_name: :test,
      files: %{
        "lib/test_web/endpoint.ex" => """
        defmodule TestWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :test
        end
        """,
        "config/config.exs" => "import Config\n",
        "config/dev.exs" => "import Config\n"
      }
    )
    |> Igniter.compose_task("phoenix_bun_assets.install", argv)
  end

  describe "defaults (managed bun, no tailwind)" do
    test "renders build.ts with the app name substituted and no tailwind plugin" do
      installed()
      |> assert_creates("assets/build.ts", fn contents ->
        assert contents =~ ~s(const stageDir = ".build-stage")
        assert contents =~ "phoenix-colocated/test"
        assert contents =~ "[assets] no changes"
        assert contents =~ "stdin closed, exiting"
        assert contents =~ "reaped orphaned watcher"
        refute contents =~ "<%= @app %>"
        refute contents =~ "bun-plugin-tailwind"
        refute contents =~ "plugins:"
      end)
    end

    test "configures the :bun profile" do
      assert_has_patch(installed(), "config/config.exs", """
      + |config :bun,
      """)
    end

    test "wires the managed (MFA) dev watcher" do
      assert_has_patch(installed(), "config/dev.exs", """
      + |  watchers: [bun: {Bun, :install_and_run, [:default, ~w(watch)]}],
      """)
    end

    test "sets live_reload patterns" do
      assert_has_patch(installed(), "config/dev.exs", """
      + |    patterns: [
      """)
    end

    test "adds managed asset aliases" do
      assert_has_patch(installed(), "mix.exs", """
      + |      "assets.build": ["compile", "bun default run build.ts"],
      """)
    end

    test "ignores the staging dir" do
      assert_has_patch(installed(), ".gitignore", """
      + |/assets/.build-stage/
      """)
    end

    test "produces no issues" do
      assert installed().issues == []
    end
  end

  describe "project scaffolding" do
    test "creates the full assets project when none exists" do
      igniter = installed()

      assert_creates(igniter, "assets/package.json", fn contents ->
        assert contents =~ ~s("typecheck": "tsc --noEmit -p tsconfig.json")
        refute contents =~ "tailwindcss"
      end)

      assert_creates(igniter, "assets/tsconfig.json", fn contents ->
        assert contents =~ ~s("include": ["js/**/*"])
      end)

      assert_creates(igniter, "assets/tsconfig.hooks.json", fn contents ->
        assert contents =~ "phoenix-colocated/test"
        refute contents =~ "<%= @app %>"
      end)

      assert_creates(igniter, "assets/js/app.ts", fn contents ->
        assert contents =~ ~s(import { LiveSocket } from "phoenix_live_view";)
        assert contents =~ "phoenix-colocated/test"
        refute contents =~ "<%= @app %>"
      end)

      assert_creates(igniter, "assets/css/app.css", fn contents ->
        assert contents =~ "phoenix-colocated/test/colocated.css"
        refute contents =~ "tailwindcss"
      end)

      assert_creates(igniter, "assets/.gitignore", fn contents ->
        assert contents =~ "node_modules"
      end)
    end

    test "tailwind scaffolds package.json deps and app.css import" do
      igniter = installed(["--tailwind"])

      assert_creates(igniter, "assets/package.json", fn contents ->
        assert contents =~ ~s("tailwindcss": "^4")
        assert contents =~ ~s("bun-plugin-tailwind": "latest")
      end)

      assert_creates(igniter, "assets/css/app.css", fn contents ->
        assert contents =~ ~s(@import "tailwindcss";)
      end)
    end

    test "leaves existing files untouched" do
      existing = %{
        "lib/test_web/endpoint.ex" => """
        defmodule TestWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :test
        end
        """,
        "config/config.exs" => "import Config\n",
        "config/dev.exs" => "import Config\n",
        "assets/package.json" => ~s({"name": "my-existing-assets"}\n),
        "assets/js/app.ts" => "// my hand-written entrypoint\n"
      }

      igniter =
        test_project(app_name: :test, files: existing)
        |> Igniter.compose_task("phoenix_bun_assets.install", [])

      # Pre-existing files are not recreated/overwritten...
      refute_creates(igniter, "assets/package.json")
      refute_creates(igniter, "assets/js/app.ts")
      # ...but missing scaffold files are still created.
      assert_creates(igniter, "assets/tsconfig.json")
      assert_creates(igniter, "assets/build.ts")
    end
  end

  describe "entry point detection" do
    defp project_with(extra_files) do
      base = %{
        "lib/test_web/endpoint.ex" => """
        defmodule TestWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :test
        end
        """,
        "config/config.exs" => "import Config\n",
        "config/dev.exs" => "import Config\n"
      }

      test_project(app_name: :test, files: Map.merge(base, extra_files))
      |> Igniter.compose_task("phoenix_bun_assets.install", [])
    end

    test "defaults to js/app.ts and css/app.css, scaffolding both" do
      igniter = project_with(%{})

      assert_creates(igniter, "assets/build.ts", fn contents ->
        assert contents =~ ~s(entrypoints: ["js/app.ts", "css/app.css"])
      end)

      assert_creates(igniter, "assets/js/app.ts")
      assert_creates(igniter, "assets/css/app.css")
    end

    test "reuses an existing app.js and does not scaffold app.ts" do
      igniter = project_with(%{"assets/js/app.js" => "// existing phoenix entry\n"})

      assert_creates(igniter, "assets/build.ts", fn contents ->
        assert contents =~ ~s(entrypoints: ["js/app.js", "css/app.css"])
      end)

      # We must not create a competing TypeScript entry next to the real one.
      refute_creates(igniter, "assets/js/app.ts")
      # CSS still scaffolds since there was no existing css entry.
      assert_creates(igniter, "assets/css/app.css")
    end

    test "prefers an existing app.ts over app.js" do
      igniter =
        project_with(%{
          "assets/js/app.ts" => "// existing ts entry\n",
          "assets/js/app.js" => "// stale js entry\n"
        })

      assert_creates(igniter, "assets/build.ts", fn contents ->
        assert contents =~ ~s(entrypoints: ["js/app.ts", "css/app.css"])
      end)

      refute_creates(igniter, "assets/js/app.ts")
    end

    test "reuses an existing css/app.css without scaffolding it" do
      igniter = project_with(%{"assets/css/app.css" => "/* existing */\n"})

      assert_creates(igniter, "assets/build.ts", fn contents ->
        assert contents =~ ~s(entrypoints: ["js/app.ts", "css/app.css"])
      end)

      refute_creates(igniter, "assets/css/app.css")
    end
  end

  describe "--bun system" do
    test "does not configure a :bun profile" do
      installed(["--bun", "system"])
      |> refute_has_patch("config/config.exs", "config :bun")
    end

    test "wires a raw-command dev watcher against PATH bun" do
      # Sourceror reformats the tuple across lines, so assert on the collapsed
      # (whitespace-stripped) content rather than an exact patch layout.
      dev = applied_content(installed(["--bun", "system"]), "config/dev.exs")
      collapsed = String.replace(dev, ~r/\s+/, "")

      assert collapsed =~ ~s({"bun",["run","build.ts","watch")
      assert collapsed =~ "NODE_PATH"
      refute collapsed =~ "install_and_run"
    end

    test "adds aliases that call the bun executable directly" do
      assert_has_patch(installed(["--bun", "system"]), "mix.exs", """
      + |      "assets.build": ["compile", "cmd --cd assets bun run build.ts"],
      """)
    end

    test "still creates build.ts and produces no issues" do
      igniter = installed(["--bun", "system"])
      assert igniter.issues == []
      assert_creates(igniter, "assets/build.ts")
    end
  end

  describe "--tailwind" do
    test "wires the tailwind plugin into build.ts" do
      installed(["--tailwind"])
      |> assert_creates("assets/build.ts", fn contents ->
        assert contents =~ ~s(import tailwind from "bun-plugin-tailwind";)
        assert contents =~ "plugins: [tailwind],"
      end)
    end

    test "ignores assets/node_modules when tailwind is enabled" do
      assert_has_patch(installed(["--tailwind"]), ".gitignore", """
      + |/assets/node_modules/
      """)
    end

    test "does not ignore assets/node_modules without tailwind" do
      installed()
      |> refute_has_patch(".gitignore", "/assets/node_modules/")
    end
  end

  describe "--install-deps" do
    test "queues no bun add task by default" do
      igniter = installed(["--tailwind"])
      refute Enum.any?(igniter.tasks, fn t -> match?({"bun", _}, t) or match?({"cmd", _}, t) end)
    end

    test "system mode queues `cmd --cd assets bun add` for tailwind packages" do
      installed(["--bun", "system", "--tailwind", "--install-deps"])
      |> assert_has_task("cmd", [
        "--cd",
        "assets",
        "bun",
        "add",
        "tailwindcss",
        "bun-plugin-tailwind"
      ])
    end

    test "managed mode queues a `bun deps add` task and configures the deps profile" do
      igniter = installed(["--tailwind", "--install-deps"])

      assert_has_task(igniter, "bun", ["deps", "add", "tailwindcss", "bun-plugin-tailwind"])

      assert_has_patch(igniter, "config/config.exs", """
      + |  deps: [args: [], cd: Path.expand("../assets", __DIR__)]
      """)
    end

    test "is a no-op with a notice when there are no npm packages to add" do
      igniter = installed(["--install-deps"])
      refute Enum.any?(igniter.tasks, fn t -> match?({"bun", _}, t) or match?({"cmd", _}, t) end)
      assert_has_notice(igniter, &(&1 =~ "--install-deps had no effect"))
    end
  end

  describe "invalid --bun value" do
    test "adds an issue" do
      igniter = installed(["--bun", "nonsense"])
      assert Enum.any?(igniter.issues, &(&1 =~ "Invalid --bun value"))
    end
  end

  # Helper: assert a file's pending diff does NOT contain a substring.
  defp refute_has_patch(igniter, path, substring) do
    refute Igniter.Test.diff(igniter, only: [path]) =~ substring
    igniter
  end

  # Helper: the pending content for a path, with diff gutter (line numbers and
  # the `+ |` / ` |` prefixes) stripped so callers can match on raw source.
  defp applied_content(igniter, path) do
    igniter
    |> Igniter.Test.diff(only: [path])
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace(&1, ~r/^.*?\|/, ""))
  end
end
