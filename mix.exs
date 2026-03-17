defmodule SelectoPostgrexMix.MixProject do
  use Mix.Project

  def project do
    [
      app: :selecto_postgrex_mix,
      version: "0.1.2",
      elixir: "~> 1.18",
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
      selecto_mix_dep(),
      {:postgrex, "~> 0.17"},
      {:igniter, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp selecto_mix_dep do
    if use_local_ecosystem?() do
      {:selecto_mix, path: "../selecto_mix"}
    else
      {:selecto_mix, ">= 0.4.0"}
    end
  end

  defp use_local_ecosystem? do
    case System.get_env("SELECTO_ECOSYSTEM_USE_LOCAL") do
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      _ -> false
    end
  end

  defp description do
    "Mix tasks for Selecto domain generation via direct Postgrex introspection (no Ecto required)"
  end

  defp package do
    [
      maintainers: ["Selecto Team"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/selectodb/selecto_postgrex_mix",
        "SQL Patterns" => "https://seeken.github.io/selecto-sql-patterns",
        "Demo (Fly)" => "https://testselecto.fly.dev"
      }
    ]
  end
end
