defmodule Mix.Tasks.SelectoPostgrexMix.Install do
  @shortdoc "Install Selecto Postgrex dependencies"
  @moduledoc """
  Install Selecto Postgrex ecosystem dependencies and run SelectoComponents integration.

  This task is a package-scoped alias of `mix selecto_postgrex.install` and supports
  `mix igniter.install selecto_postgrex_mix` installer execution.

  ## Usage

      mix selecto_postgrex_mix.install
      mix selecto_postgrex_mix.install --development-mode --source your-fork
      mix selecto_postgrex_mix.install --postgis
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    Mix.Tasks.SelectoPostgrex.Install.info([], nil)
  end

  def supports_umbrella?, do: true

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    Mix.Tasks.SelectoPostgrex.Install.igniter(igniter)
  end
end
