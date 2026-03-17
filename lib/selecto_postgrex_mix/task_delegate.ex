defmodule SelectoPostgrexMix.TaskDelegate do
  @moduledoc false

  def run(shared_task, args, postgrex_task) do
    Mix.shell().info(
      "[deprecated] `mix #{postgrex_task}` now delegates to `mix #{shared_task}` during consolidation"
    )

    Mix.Task.reenable(shared_task)
    Mix.Task.run(shared_task, args)
  end
end
