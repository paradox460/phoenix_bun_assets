defmodule Mix.Tasks.PhoenixBunAssets.Install do
  @example "mix igniter.install phoenix_bun_assets"

  @shortdoc "Installs the change-detecting Bun asset builder into a Phoenix app."

  @moduledoc """
  #{@shortdoc}

  ## Example

  ```sh
  #{@example}
  ```

  This installer bootstraps a complete Bun + TypeScript asset pipeline,
  replacing the default esbuild/tailwind Mix tasks. It:

    * scaffolds the `assets/` project — `build.ts` (the deterministic,
      change-detecting build script), `package.json`, `tsconfig.json`,
      `tsconfig.hooks.json`, `.gitignore`, `js/app.ts`, and `css/app.css` —
      creating each file only if it does not already exist,
    * configures the Phoenix endpoint `watchers` to run `build.ts watch` in dev,
    * ensures the `live_reload` patterns watch `priv/static/**/*.{js,css,...}`,
    * adds `assets.build` / `assets.deploy` Mix aliases,
    * ignores the generated `assets/.build-stage/` staging dir.

  Any file that already exists in the target project is left untouched, so it is
  safe to run against a project that already has some of these files. The
  generated `build.ts` targets whatever entry points already exist — an existing
  `js/app.ts` or `js/app.js` (and `css/app.css`) is reused instead of scaffolding
  a competing one — so a standard Phoenix app builds without manual edits.

  ## Bun binary

  By default the installer adds the `:bun` dependency, which downloads and
  manages the bun binary for you (via `mix bun.install`). If you already provide
  bun another way — [mise](https://mise.jdx.dev), system package manager, a
  Docker base image, `asdf`, etc. — pass `--bun system` and the installer will
  set up the watcher and aliases to a `bun` executable on your `PATH` instead,
  adding no dependency and no `:bun` config.

  ## Tailwind

  Pass `--tailwind` to enable Tailwind CSS v4 compilation through Bun's bundler
  (via the `bun-plugin-tailwind` plugin). The build script is built to load the
  plugin, and the installer prints the `bun add` command for the required npm
  packages.

  ## Options

    * `--bun` - how bun is provided: `managed` (default, adds the `:bun` dep and
      manages the binary) or `system` (assumes `bun` is already on your `PATH`).
    * `--bun-version` - the bun version to pin in config. Only used with
      `--bun managed`. Defaults to a recent stable.
    * `--tailwind` - enable Tailwind CSS v4 compilation through Bun. Defaults to false.
    * `--install-deps` - after installing, run `bun add` in `assets/` to fetch the
      npm packages (currently only Tailwind's). Off by default; when off, the
      installer just prints the `bun add` command for you to run yourself.
  """

  use Igniter.Mix.Task

  @default_bun_version "1.3.0"

  @impl Igniter.Mix.Task
  def info(argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :phoenix_bun_assets,
      example: @example,
      # Only add/install `:bun` in managed mode. In system mode the user
      # provides bun themselves (mise, system package, Docker image, ...).
      installs: if(managed?(argv), do: [{:bun, "~> 1.5 or ~> 2.0"}], else: []),
      schema: [bun: :string, bun_version: :string, tailwind: :boolean, install_deps: :boolean],
      defaults: [
        bun: "managed",
        bun_version: @default_bun_version,
        tailwind: false,
        install_deps: false
      ]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    app = Igniter.Project.Application.app_name(igniter)
    strategy = bun_strategy(igniter.args.options[:bun])
    bun_version = igniter.args.options[:bun_version] || @default_bun_version
    tailwind? = igniter.args.options[:tailwind] == true
    install_deps? = igniter.args.options[:install_deps] == true

    {igniter, endpoint} =
      Igniter.Libs.Phoenix.select_endpoint(
        igniter,
        nil,
        "Which endpoint should run the Bun watcher?"
      )

    cond do
      is_nil(endpoint) ->
        Igniter.add_issue(igniter, """
        No Phoenix endpoint found. phoenix_bun_assets requires a Phoenix application
        with an endpoint to connect the asset watcher and live reload to.
        """)

      strategy == :error ->
        Igniter.add_issue(igniter, """
        Invalid --bun value: #{inspect(igniter.args.options[:bun])}.
        Expected "managed" (adds the :bun dep) or "system" (bun already on PATH).
        """)

      true ->
        {js_entry, css_entry} = detect_entrypoints(igniter)

        igniter
        |> bootstrap_project_files(app, tailwind?, js_entry, css_entry)
        |> maybe_configure_bun_profile(strategy, bun_version)
        |> configure_watcher(endpoint, strategy)
        |> configure_live_reload(endpoint)
        |> add_asset_aliases(strategy)
        |> ignore_generated_dirs(tailwind?)
        |> maybe_install_deps(strategy, tailwind?, install_deps?)
        |> add_completion_notice(strategy, tailwind?, install_deps?, js_entry, css_entry)
    end
  end

  @default_js_entry "js/app.ts"
  @default_css_entry "css/app.css"

  # Resolves the JS/CSS entry points `build.ts` should bundle. Prefers an
  # existing TypeScript entry, then an existing Phoenix-shipped `app.js`/`app.css`,
  # otherwise falls back to the scaffolded TypeScript defaults.
  defp detect_entrypoints(igniter) do
    {detect_entry(igniter, "js", ["app.ts", "app.js"], @default_js_entry),
     detect_entry(igniter, "css", ["app.css"], @default_css_entry)}
  end

  defp detect_entry(igniter, dir, candidates, default) do
    Enum.find_value(candidates, default, fn file ->
      rel = "#{dir}/#{file}"
      if Igniter.exists?(igniter, "assets/#{rel}"), do: rel
    end)
  end

  # Renders the Bun/TypeScript asset scaffold. Every file uses `on_exists: :skip`,
  # so an existing project's own files are never touched — we only fill in what's
  # missing to reach a working pipeline. The generated `build.ts` targets the
  # detected entry points, and the `app.ts`/`app.css` starters are only rendered
  # when the project has no existing entry of that kind.
  defp bootstrap_project_files(igniter, app, tailwind?, js_entry, css_entry) do
    assigns = [
      app: app,
      tailwind: tailwind?,
      js_entry: js_entry,
      css_entry: css_entry
    ]

    files =
      [
        {"build.ts.eex", "assets/build.ts"},
        {"package.json.eex", "assets/package.json"},
        {"tsconfig.json.eex", "assets/tsconfig.json"},
        {"tsconfig.hooks.json.eex", "assets/tsconfig.hooks.json"},
        {"gitignore.eex", "assets/.gitignore"}
      ] ++
        if(js_entry == @default_js_entry,
          do: [{"app.ts.eex", "assets/#{@default_js_entry}"}],
          else: []
        ) ++
        if(css_entry == @default_css_entry,
          do: [{"app.css.eex", "assets/#{@default_css_entry}"}],
          else: []
        )

    Enum.reduce(files, igniter, fn {template, target}, acc ->
      Igniter.copy_template(acc, template_path(template), target, assigns, on_exists: :skip)
    end)
  end

  defp template_path(name) do
    Path.join(:code.priv_dir(:phoenix_bun_assets), "templates/#{name}")
  end

  # Managed mode only: config :bun, version: "...", default: [args:, cd:, env:].
  # System mode provides bun itself, so no dep and no profile are configured.
  defp maybe_configure_bun_profile(igniter, :system, _bun_version), do: igniter

  defp maybe_configure_bun_profile(igniter, :managed, bun_version) do
    igniter
    |> Igniter.Project.Config.configure(
      "config.exs",
      :bun,
      [:version],
      bun_version
    )
    |> Igniter.Project.Config.configure(
      "config.exs",
      :bun,
      [:default],
      {:code,
       Sourceror.parse_string!("""
       [
         args: ~w(run build.ts),
         cd: Path.expand("../assets", __DIR__),
         env: %{"NODE_PATH" => #{node_path_code()}}
       ]
       """)}
    )
  end

  @tailwind_packages ~w(tailwindcss bun-plugin-tailwind)

  # Queues a post-apply `bun add` in `assets/`, only when the user opted in
  # AND there are npm packages to fetch (currently only Tailwind's). Tasks added
  # here run after Igniter commits its file/config changes.
  defp maybe_install_deps(igniter, _strategy, _tailwind?, false), do: igniter

  defp maybe_install_deps(igniter, _strategy, false, true) do
    # --install-deps with nothing to install: Phoenix's own deps resolve via
    # NODE_PATH, so there is no npm package to add. Say so instead of no-op'ing.
    Igniter.add_notice(
      igniter,
      "--install-deps had no effect: no npm packages to add (enable --tailwind to add Tailwind's)."
    )
  end

  defp maybe_install_deps(igniter, :system, true, true) do
    Igniter.add_task(igniter, "cmd", ["--cd", "assets", "bun", "add" | @tailwind_packages])
  end

  defp maybe_install_deps(igniter, :managed, true, true) do
    # The managed bun binary lives at `_build/bun`, reachable through the `mix bun`
    # task via an empty-args profile scoped to `assets/`.
    igniter
    |> Igniter.Project.Config.configure(
      "config.exs",
      :bun,
      [:deps],
      {:code,
       Sourceror.parse_string!("""
       [args: [], cd: Path.expand("../assets", __DIR__)]
       """)}
    )
    |> Igniter.add_task("bun", ["deps", "add" | @tailwind_packages])
  end

  # Managed: MFA watcher {Bun, :install_and_run, [...]} (auto-installs the binary).
  # System: raw command watcher {"bun", ["run", "build.ts", "watch", cd:, env:]}.
  defp configure_watcher(igniter, endpoint, strategy) do
    watcher = watcher_code(strategy)

    Igniter.Project.Config.configure(
      igniter,
      "dev.exs",
      app_name(igniter),
      [endpoint, :watchers],
      {:code, Sourceror.parse_string!("[bun: #{watcher}]")},
      updater: fn zipper ->
        # Append our watcher if the key already holds a list.
        case Igniter.Code.List.append_new_to_list(
               zipper,
               Sourceror.parse_string!("{:bun, #{watcher}}")
             ) do
          {:ok, zipper} -> {:ok, zipper}
          :error -> {:ok, zipper}
        end
      end
    )
  end

  defp configure_live_reload(igniter, endpoint) do
    patterns =
      Sourceror.parse_string!("""
      [
        ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"priv/gettext/.*(po)$",
        ~r"lib/#{web_dir(igniter)}/(controllers|live|components)/.*(ex|heex)$"
      ]
      """)

    Igniter.Project.Config.configure(
      igniter,
      "dev.exs",
      app_name(igniter),
      [endpoint, :live_reload, :patterns],
      {:code, patterns},
      updater: fn zipper -> {:ok, zipper} end
    )
  end

  defp add_asset_aliases(igniter, strategy) do
    {build, deploy} = alias_commands(strategy)

    igniter
    |> Igniter.Project.TaskAliases.add_alias("assets.build", build, if_exists: :ignore)
    |> Igniter.Project.TaskAliases.add_alias("assets.deploy", deploy, if_exists: :ignore)
  end

  # Managed mode drives bun through the `mix bun` task; system mode calls the
  # `bun` executable directly via `mix cmd` from the assets dir.
  defp alias_commands(:managed) do
    {["compile", "bun default run build.ts"],
     ["compile", "bun default run build.ts deploy", "phx.digest"]}
  end

  defp alias_commands(:system) do
    {["compile", "cmd --cd assets bun run build.ts"],
     ["compile", "cmd --cd assets bun run build.ts deploy", "phx.digest"]}
  end

  @staging_ignore "# Bun build staging dir (deterministic build source for the change-detecting copy).\n/assets/.build-stage/\n"
  @node_modules_ignore "# Bun-managed npm packages (Tailwind and its plugin).\n/assets/node_modules/\n"

  # Ensures each ignore entry is present, appending only the ones missing.
  # `--tailwind` pulls in npm packages via `bun add`, so `assets/node_modules/`
  # must be ignored too (many Phoenix apps already ignore it — we add it only if absent).
  defp ignore_generated_dirs(igniter, tailwind?) do
    entries =
      [{"/assets/.build-stage/", @staging_ignore}] ++
        if tailwind?, do: [{"/assets/node_modules/", @node_modules_ignore}], else: []

    Igniter.create_or_update_file(igniter, ".gitignore", gitignore_body(entries), fn source ->
      content = Rewrite.Source.get(source, :content)

      addition =
        entries
        |> Enum.reject(fn {marker, _} -> String.contains?(content, marker) end)
        |> gitignore_body()

      if addition == "" do
        source
      else
        Rewrite.Source.update(source, :content, ensure_trailing_newline(content) <> addition)
      end
    end)
  end

  defp gitignore_body(entries) do
    case Enum.map_join(entries, "\n", fn {_marker, block} -> block end) do
      "" -> ""
      body -> "\n" <> body
    end
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end

  defp add_completion_notice(igniter, strategy, tailwind?, install_deps?, js_entry, css_entry) do
    steps =
      [bun_step(strategy)] ++
        tailwind_steps(tailwind?, install_deps?) ++
        [
          "Run `mix assets.build` for a one-off build, or start `mix phx.server` for the dev watcher."
        ]

    numbered =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} -> "  #{i}. #{step}" end)

    Igniter.add_notice(igniter, """
    phoenix_bun_assets installed. Your `assets/` project has been scaffolded
    (existing files were left untouched).

    build.ts bundles: #{js_entry} and #{css_entry}.
    #{entry_note(js_entry, css_entry)}
    Next steps:
    #{numbered}

    See the package README for the design rationale (change detection, determinism, orphan hygiene).
    """)
  end

  # Notes when an existing (non-scaffolded) JS/CSS entry was detected and reused.
  defp entry_note(js_entry, css_entry) do
    non_ts = js_entry != @default_js_entry

    cond do
      non_ts ->
        "Detected your existing `assets/#{js_entry}` — build.ts targets it as-is. " <>
          "Rename it to `.ts` (and update the entry in build.ts) to get TypeScript type-checking.\n"

      css_entry != @default_css_entry ->
        "Detected your existing `assets/#{css_entry}` — build.ts targets it as-is.\n"

      true ->
        ""
    end
  end

  defp bun_step(:managed), do: "Run `mix bun.install` to download the bun binary."

  defp bun_step(:system),
    do: "Ensure `bun` is available on your PATH (mise, system package, Docker image, ...)."

  defp tailwind_steps(false, _install_deps?), do: []

  # Deps queued via --install-deps: nothing manual, the scaffolded app.css already
  # imports tailwindcss and the packages are being installed for you.
  defp tailwind_steps(true, true),
    do: ["Tailwind is enabled — its npm packages are being installed for you."]

  defp tailwind_steps(true, false) do
    [
      "Install the Tailwind npm packages: `cd assets && bun add tailwindcss bun-plugin-tailwind` " <>
        "(this creates `assets/package.json` + `assets/node_modules`; if `assets/package.json` " <>
        "already existed, add the packages there too)."
    ]
  end

  # --- helpers -----------------------------------------------------------

  defp app_name(igniter), do: Igniter.Project.Application.app_name(igniter)

  defp web_dir(igniter) do
    igniter
    |> Igniter.Libs.Phoenix.web_module()
    |> inspect()
    |> Macro.underscore()
  end

  # Bun resolves `phoenix`, `phoenix_live_view`, and the generated
  # `phoenix-colocated/<app>` package via NODE_PATH at spawn time.
  defp node_path_code do
    ~s|Enum.join([Path.expand("../deps", __DIR__), Path.expand("../_build/dev", __DIR__)], ":")|
  end

  defp watcher_code(:managed), do: "{Bun, :install_and_run, [:default, ~w(watch)]}"

  defp watcher_code(:system) do
    ~s|{"bun", ["run", "build.ts", "watch", cd: Path.expand("../assets", __DIR__), env: [{"NODE_PATH", #{node_path_code()}}]]}|
  end

  # `installs:` in info/2 runs before options are parsed into igniter.args, so we
  # peek at raw argv to decide whether to add the `:bun` dep.
  defp managed?(argv) do
    case OptionParser.parse(argv, switches: [bun: :string]) do
      {opts, _, _} -> bun_strategy(opts[:bun]) != :system
    end
  end

  defp bun_strategy(nil), do: :managed
  defp bun_strategy("managed"), do: :managed
  defp bun_strategy("system"), do: :system
  defp bun_strategy(_), do: :error
end
