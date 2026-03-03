defmodule SelectoPostgrexMix.MixProject do
  use Mix.Project

  def project do
    [
      app: :selecto_postgrex_mix,
      version: "0.1.2",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:postgrex, "~> 0.17"},
      {:igniter, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Mix tasks for Selecto domain generation via direct Postgrex introspection (no Ecto required)"
  end

  defp package do
    [
      maintainers: ["Selecto Team"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/selectodb/selecto_postgrex_mix"}
    ]
  end
end
