defmodule Mix.Tasks.SelectoPostgrex.Validate.ParameterizedJoins do
  @shortdoc "Validate parameterized join configurations in Selecto domains"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.validate.parameterized_joins`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.validate.parameterized_joins",
      args,
      "selecto_postgrex.validate.parameterized_joins"
    )
  end
end
