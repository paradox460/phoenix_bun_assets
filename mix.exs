defmodule PhoenixBunAssets.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/paradox460/phoenix_bun_assets"

  def project do
    [
      app: :phoenix_bun_assets,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      name: "PhoenixBunAssets"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # `bun` installs and manages the bun binary; the installer wires it up as
      # the endpoint watcher. Optional so it is only pulled when the installer runs.
      {:bun, "~> 1.5 or ~> 2.0", optional: true},
      # Igniter powers the `phoenix_bun_assets.install` task. Optional so end
      # users who only vendor the template are not forced to depend on it.
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Deterministic, change-detecting Bun asset builder for Phoenix, with an Igniter installer."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
