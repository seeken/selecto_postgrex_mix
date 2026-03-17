defmodule Mix.Tasks.SelectoPostgrex.Gen.Domain do
  @shortdoc "Generate Selecto domains from PostgreSQL tables"
  @moduledoc """
  Deprecated Postgrex-specific wrapper for `mix selecto.gen.domain --adapter postgresql`.

  This task remains as a compatibility shell while `selecto_postgrex_mix` is being
  consolidated into the shared `selecto_mix` flow.

  Examples:

      mix selecto_postgrex.gen.domain --table products
      mix selecto_postgrex.gen.domain --all --live

  Equivalent shared command:

      mix selecto.gen.domain --adapter postgresql ...
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    SelectoPostgrexMix.TaskDelegate.run(
      "selecto.gen.domain",
      ensure_adapter_arg(args),
      "selecto_postgrex.gen.domain"
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
