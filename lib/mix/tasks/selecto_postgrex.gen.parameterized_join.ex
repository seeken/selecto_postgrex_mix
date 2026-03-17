defmodule Mix.Tasks.SelectoPostgrex.Gen.ParameterizedJoin do
  @shortdoc "Generate parameterized join configuration templates"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.gen.parameterized_join`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.gen.parameterized_join",
      args,
      "selecto_postgrex.gen.parameterized_join"
    )
  end
end
