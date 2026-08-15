# PhoenixBunAssets

[Bun](https://bun.sh) based asset bundler/builder for Phoenix, with full support
for [Colocated
CSS](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.ColocatedCSS.html)
and [JS](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.ColocatedJS.html)

Uses [Igniter](https://hexdocs.pm/igniter) to help install, and then provides a
`build.ts` template for your specific setup.

Replaces the default esbuild/tailwind Mix tasks with a single ~120-line
TypeScript build script that Bun runs directly. The script is deliberately *not*
hidden behind a Mix runner — see [Why a template, not a
runner](#why-a-template-not-a-runner).

## What you get

- **Change-detecting writes.** A served bundle
  (`priv/static/assets/js/app.js`, `.../css/app.css`) is written only when its
  bytes actually change. Identical rebuilds produce zero writes → zero
  `live_reload` events → no spurious full-page reloads and no self-sustaining
  reload loops.
- **Deterministic output.** Bun builds into a fixed, unwatched staging dir
  (`assets/.build-stage/`) so its inline-sourcemap `sources` prefix is stable
  across rebuilds; change detection then reliably skips no-op writes.
- **Orphan-process hygiene.** The dev watcher exits on stdin EOF (its Erlang
  port closing when the BEAM dies) and reaps stale predecessors via a pidfile,
  so abnormally-killed dev servers never leak background bundlers.

## Installation

This package installs via [Igniter](https://hexdocs.pm/igniter). If you don't
already have Igniter, install the archive once (globally):

```sh
mix archive.install hex igniter_new
```

Then run the installer, which adds `phoenix_bun_assets` to your deps, fetches
it, and runs its setup:

```sh
mix igniter.install phoenix_bun_assets
```

> Already have Igniter as a dependency in your project? You can skip the archive
> and run `mix igniter.install phoenix_bun_assets` directly.

The installer will:

1. scaffold the `assets/` dir for this project, creating each file **only if it does not
   already exist** (existing files are left untouched):
   - `assets/build.ts` — the deterministic, change-detecting build script
   - `assets/package.json` — `typecheck` scripts + TypeScript dev deps
   - `assets/tsconfig.json` — editor/CI type-checking of `js/` sources
   - `assets/tsconfig.hooks.json` — type-checking of colocated LiveView hooks
   - `assets/.gitignore` — node_modules, caches, `.build-stage`, etc.
   - `assets/js/app.ts` — the LiveView entry point
   - `assets/css/app.css` — the CSS entry point
2. change your Phoenix endpoint `watchers` to run `build.ts watch` in dev
3. ensure `live_reload.patterns` watch `priv/static/**/*.{js,css,png,...}`
4. add `assets.build` / `assets.deploy` Mix aliases
5. add `/assets/.build-stage/` to `.gitignore`
6. and, in the default **managed** mode, add the [`:bun`](https://hex.pm/packages/bun)
   dependency and a `:bun` `:default` profile in `config/config.exs`

Because every generated file is create-if-absent, the installer is safe to run
on a project that already has an `assets/` directory — it only fills in what is
missing to reach a working pipeline. If you already have an `app.js` entry point
you want to keep, either delete it (so the TypeScript `app.ts` is used) or point
the `entrypoints` in `build.ts` at it.

Then:

```sh
mix bun.install     # download the bun binary (managed mode only)
mix assets.build    # one-off build
mix phx.server      # dev watcher
```

### Options

- `--bun` — how bun is provided:
  - `managed` (default) — adds the `:bun` dependency, which downloads and
    manages the bun binary (`mix bun.install`), and configures a `:bun` profile.
  - `system` — assumes `bun` is already on your `PATH`. Adds **no** dependency
    and **no** `:bun` config; the watcher and aliases invoke the `bun`
    executable directly. Use this if you install bun via
    [mise](https://mise.jdx.dev), a system package manager, `asdf`, or a Docker
    base image.
- `--bun-version` — the bun version to pin in config. Managed mode only
  (default: a recent stable).
- `--tailwind` — enable Tailwind CSS v4 compilation through Bun's bundler (via
  the [`bun-plugin-tailwind`](https://www.npmjs.com/package/bun-plugin-tailwind)
  plugin). The build script is setup to load the plugin. Defaults to off. Unless
  you also pass `--install-deps`, the installer just prints the `bun add` command
  for the required npm packages for you to run.
- `--install-deps` — after the install completes, automatically run `bun add`
  inside `assets/` to fetch the npm packages (currently only Tailwind's). Off by
  default. Has no effect without `--tailwind` (Phoenix's own JS deps resolve via
  `NODE_PATH`, so there is nothing to fetch from npm otherwise).

Examples:

```sh
# I manage bun with mise, want Tailwind, and want the deps installed for me:
mix igniter.install phoenix_bun_assets --bun system --tailwind --install-deps

# Let the package manage the bun binary (default):
mix igniter.install phoenix_bun_assets
```

## Manual installation (without Igniter)

If you'd rather not run the installer, copy `priv/templates/build.ts.eex` to
`assets/build.ts` (replace `<%%= @app %>` with your OTP app name; if you want
Tailwind, keep the `bun-plugin-tailwind` import and `plugins: [tailwind]`
lines, otherwise drop them).

### Managed bun (the package downloads the binary)

```elixir
# mix.exs
defp deps do
  [
    {:bun, "~> 1.5 or ~> 2.0", runtime: Mix.env() == :dev}
    # ...
  ]
end

defp aliases do
  [
    "assets.build": ["compile", "bun default run build.ts"],
    "assets.deploy": ["compile", "bun default run build.ts deploy", "phx.digest"]
  ]
end
```

```elixir
# config/config.exs
config :bun,
  version: "1.3.0",
  default: [
    args: ~w(run build.ts),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" =>
        Enum.join(
          [Path.expand("../deps", __DIR__), Path.expand("../_build/dev", __DIR__)],
          ":"
        )
    }
  ]
```

```elixir
# config/dev.exs
config :my_app, MyAppWeb.Endpoint,
  watchers: [bun: {Bun, :install_and_run, [:default, ~w(watch)]}]
```

### System bun (already on your PATH)

No `:bun` dependency and no `:bun` config. The watcher and aliases invoke the
`bun` executable directly:

```elixir
# mix.exs
defp aliases do
  [
    "assets.build": ["compile", "cmd --cd assets bun run build.ts"],
    "assets.deploy": ["compile", "cmd --cd assets bun run build.ts deploy", "phx.digest"]
  ]
end
```

```elixir
# config/dev.exs
config :my_app, MyAppWeb.Endpoint,
  watchers: [
    bun:
      {"bun", ["run", "build.ts", "watch", cd: Path.expand("../assets", __DIR__),
       env: [{"NODE_PATH", Enum.join([Path.expand("../deps", __DIR__), Path.expand("../_build/dev", __DIR__)], ":")}]]}
  ]
```

### Common (both strategies)

```elixir
# config/dev.exs
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*\.po$",
      ~r"lib/my_app_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]
```

```gitignore
# .gitignore
/assets/.build-stage/
/priv/static/assets/
```

For Tailwind, also install the npm packages and add the import. `bun add`
creates `assets/package.json`, `assets/bun.lock`, and `assets/node_modules`
for you — no manual manifest needed:

```sh
cd assets && bun add tailwindcss bun-plugin-tailwind
```

```css
/* assets/css/app.css — first line */
@import "tailwindcss";
```

```gitignore
# .gitignore — Tailwind pulls in npm packages, so ignore them too
/assets/node_modules/
```

## Why a template, not a runner

The `esbuild` and `tailwind` Hex packages are thin **installer + runner**
shims: they download a platform binary and shell out to it with CLI flags
(`--bundle --outdir=...`). All the intelligence lives in the generic,
flag-driven CLI, which is why those packages are reusable unchanged.

Our value is the opposite: **project-agnostic build *logic*** that the
`bun build` CLI cannot express — inspecting each output before writing so
unchanged bundles are skipped, staging for determinism, and process-lifecycle
hygiene.
All three depend on Bun's **JavaScript API** (`Bun.build()` returning
`result.outputs` with `.arrayBuffer()`, `Bun.file`, `Bun.write`, `Bun.stdin`,
`process.kill`). You cannot move that behind a `System.cmd "bun" [flags]`
runner; it *is* a JS program.

So this package delivers the logic as a **`build.ts` template** you own in your
repo (the same way Phoenix generators copy `app.js` into your project rather
than hiding it in a dep), and relies on the existing `bun` Hex package to
manage the binary. The Igniter installer automates the copy-and-wire step.

## The two bugs this avoids

1. **Reload loop.** A naive build rewrites both bundles on every rebuild even
   when content is unchanged. Because `app.js` maps to the full-page-reload
   strategy and each reload re-runs the code reloader (which can re-touch
   inputs), the rebuild→reload→rebuild cascade can self-sustain. Change
   detection breaks it.
2. **Nondeterministic output defeats change detection.** Building *in memory*
   (no `outdir`) makes Bun's inline-sourcemap `sources` prefix nondeterministic,
   so `app.js` differs run-to-run despite identical code — the byte comparison
   never matches and bug 1 returns. Building into a fixed staging `outdir`
   restores determinism.

Together they enforce the invariant: *a rebuild writes a served bundle if that
bundle's content actually changed, and exactly one watcher is ever running.*

## License

MIT License

Copyright (c) 2026 Jeffrey Sandberg

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
