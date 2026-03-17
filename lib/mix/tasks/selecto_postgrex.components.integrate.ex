defmodule Mix.Tasks.SelectoPostgrex.Components.Integrate do
  @shortdoc "Integrate SelectoComponents hooks and styles into your Phoenix app"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.components.integrate`.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.components.integrate",
      args,
      "selecto_postgrex.components.integrate"
    )
  end
end
