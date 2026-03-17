defmodule Mix.Tasks.SelectoPostgrex.Setup do
  @shortdoc "Run generated SQL files using PostgreSQL adapter setup"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.setup --adapter postgresql`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.setup",
      ensure_adapter_arg(args),
      "selecto_postgrex.setup"
    )
  end

  defp ensure_adapter_arg(args) do
    if Enum.any?(args, &(&1 == "--adapter")) do
      args
    else
      args ++ ["--adapter", "postgresql"]
    end
  end
end
