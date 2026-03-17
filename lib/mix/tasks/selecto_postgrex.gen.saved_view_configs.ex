defmodule Mix.Tasks.SelectoPostgrex.Gen.SavedViewConfigs do
  @shortdoc "Generate SavedViewConfigs implementation using Postgrex (no Ecto)"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.gen.saved_view_configs --adapter postgresql`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.gen.saved_view_configs",
      args ++ ["--adapter", "postgresql"],
      "selecto_postgrex.gen.saved_view_configs"
    )
  end
end
