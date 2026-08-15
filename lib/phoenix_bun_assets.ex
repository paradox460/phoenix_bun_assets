defmodule PhoenixBunAssets do
  @moduledoc """
  Deterministic, change-detecting Bun asset builder for Phoenix.

  This package is primarily an **Igniter installer** plus a **build script
  template**. Unlike `esbuild`/`tailwind` (which are thin installer+runner
  wrappers around a generic, flag-driven CLI), the reusable value here is
  *build logic* that the `bun build` CLI cannot express:

    * **Change-detecting writes** — a served bundle is written only when its
      bytes actually change, so identical rebuilds push zero live-reload events.
    * **Deterministic output** — Bun builds into a fixed staging dir so the
      inline-sourcemap `sources` prefix is stable across rebuilds; change
      detection then reliably suppresses no-op writes.
    * **Orphan hygiene** — the watcher exits on stdin EOF (its Erlang port
      closing) and reaps stale predecessors via a pidfile, so abnormally-killed
      dev servers never leak background bundlers.

  Because that logic is a JavaScript program (it depends on Bun's `Bun.build`
  JS API — `result.outputs`, `arrayBuffer()`, `Bun.file`, `Bun.write`,
  `Bun.stdin`), it is delivered as a `build.ts` template copied into the target
  project rather than hidden behind a `System.cmd` runner. The `bun` Hex package
  installs and manages the actual bun binary.

  Install with:

      mix igniter.install phoenix_bun_assets

  See `Mix.Tasks.PhoenixBunAssets.Install` and the README for details.
  """

  @doc """
  Returns the default bun version pinned by the installer.
  """
  def default_bun_version, do: "1.3.0"
end
