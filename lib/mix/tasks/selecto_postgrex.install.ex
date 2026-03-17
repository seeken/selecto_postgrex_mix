defmodule Mix.Tasks.SelectoPostgrex.Install do
  @shortdoc "Install Selecto Postgrex dependencies and integrate assets"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.install`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.install",
      args,
      "selecto_postgrex.install"
    )
  end
end
