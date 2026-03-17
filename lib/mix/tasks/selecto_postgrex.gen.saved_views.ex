defmodule Mix.Tasks.SelectoPostgrex.Gen.SavedViews do
  @shortdoc "Generate SavedViews implementation using Postgrex (no Ecto)"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.gen.saved_views --adapter postgresql`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.gen.saved_views",
      args ++ ["--adapter", "postgresql"],
      "selecto_postgrex.gen.saved_views"
    )
  end
end
