defmodule Mix.Tasks.SelectoPostgrex.Gen.FilterSets do
  @shortdoc "Generate filter sets implementation using Postgrex (no Ecto)"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.gen.filter_sets --adapter postgresql`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.gen.filter_sets",
      args ++ ["--adapter", "postgresql"],
      "selecto_postgrex.gen.filter_sets"
    )
  end
end
