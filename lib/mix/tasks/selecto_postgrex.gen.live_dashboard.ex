defmodule Mix.Tasks.SelectoPostgrex.Gen.LiveDashboard do
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.gen.live_dashboard`.
  """

  use Mix.Task

  @shortdoc "Generates a LiveDashboard page for Selecto metrics"

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.gen.live_dashboard",
      args,
      "selecto_postgrex.gen.live_dashboard"
    )
  end
end
