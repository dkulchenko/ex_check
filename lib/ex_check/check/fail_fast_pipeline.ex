defmodule ExCheck.Check.FailFastPipeline do
  @moduledoc false

  def run(pending, opts) do
    throttle_fn = Keyword.fetch!(opts, :throttle_fn)
    start_fn = Keyword.fetch!(opts, :start_fn)
    finish_fn = Keyword.fetch!(opts, :finish_fn)

    halt_fn = Keyword.get(opts, :halt_fn, fn _ -> :cont end)
    cancel_fn = Keyword.get(opts, :cancel_fn, fn _ -> :ok end)
    cancel_timeout_ms = Keyword.get(opts, :cancel_timeout_ms, 1_000)

    loop(pending, %{}, [], throttle_fn, start_fn, finish_fn, halt_fn, cancel_fn, cancel_timeout_ms)
  end

  defp loop(
         pending,
         running,
         finished,
         throttle_fn,
         start_fn,
         finish_fn,
         halt_fn,
         cancel_fn,
         cancel_timeout_ms
       ) do
    {pending, running} = start_next(pending, running, finished, throttle_fn, start_fn)

    cond do
      pending == [] and map_size(running) == 0 ->
        {finished, []}

      map_size(running) == 0 ->
        {finished, pending}

      true ->
        receive do
          {ref, task_result} when is_reference(ref) and is_map_key(running, ref) ->
            {{_payload, running_payload, task}, running} = Map.pop(running, ref)
            Process.demonitor(task.ref, [:flush])

            result = finish_fn.(running_payload, task_result)
            finished = finished ++ [result]

            case halt_fn.(result) do
              :cont ->
                loop(
                  pending,
                  running,
                  finished,
                  throttle_fn,
                  start_fn,
                  finish_fn,
                  halt_fn,
                  cancel_fn,
                  cancel_timeout_ms
                )

              {:halt, reason} ->
                Enum.each(running, fn {_ref, {_payload, running_payload, _task}} ->
                  cancel_fn.(running_payload)
                end)

                {finished, timed_out_payloads} =
                  drain_running(running, finished, finish_fn, cancel_timeout_ms)

                {:halted, finished, pending, timed_out_payloads, reason}
            end

          {:DOWN, ref, :process, _pid, reason}
          when is_reference(ref) and is_map_key(running, ref) ->
            {{_payload, running_payload, task}, running} = Map.pop(running, ref)
            Process.demonitor(task.ref, [:flush])

            result = finish_fn.(running_payload, {:down, reason})
            finished = finished ++ [result]

            loop(
              pending,
              running,
              finished,
              throttle_fn,
              start_fn,
              finish_fn,
              halt_fn,
              cancel_fn,
              cancel_timeout_ms
            )
        end
    end
  end

  defp start_next(pending, running, finished, throttle_fn, start_fn) do
    running_payloads =
      Enum.map(running, fn {_ref, {payload, _running_payload, _task}} -> payload end)

    selected = throttle_fn.(pending, running_payloads, finished)

    running =
      Enum.reduce(selected, running, fn payload, running ->
        running_payload = start_fn.(payload)
        task = extract_task!(running_payload)
        Map.put(running, task.ref, {payload, running_payload, task})
      end)

    {pending -- selected, running}
  end

  defp extract_task!({:running, {_, _, _}, %Task{} = task}), do: task
  defp extract_task!(other), do: raise("unexpected running payload: #{inspect(other)}")

  defp drain_running(running, finished, finish_fn, cancel_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + cancel_timeout_ms
    do_drain_running(running, finished, finish_fn, deadline)
  end

  defp do_drain_running(running, finished, _finish_fn, _deadline) when map_size(running) == 0 do
    {finished, []}
  end

  defp do_drain_running(running, finished, finish_fn, deadline) do
    remaining_ms = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {ref, task_result} when is_reference(ref) and is_map_key(running, ref) ->
        {{_payload, running_payload, task}, running} = Map.pop(running, ref)
        Process.demonitor(task.ref, [:flush])

        result = finish_fn.(running_payload, task_result)
        do_drain_running(running, finished ++ [result], finish_fn, deadline)

      {:DOWN, ref, :process, _pid, reason} when is_reference(ref) and is_map_key(running, ref) ->
        {{_payload, running_payload, task}, running} = Map.pop(running, ref)
        Process.demonitor(task.ref, [:flush])

        result = finish_fn.(running_payload, {:down, reason})
        do_drain_running(running, finished ++ [result], finish_fn, deadline)
    after
      remaining_ms ->
        Enum.each(running, fn {_ref, {_payload, _running_payload, task}} ->
          Process.demonitor(task.ref, [:flush])
          _ = Task.shutdown(task, :brutal_kill)
        end)

        timed_out_payloads =
          Enum.map(running, fn {_ref, {payload, _running_payload, _task}} -> payload end)

        {finished, timed_out_payloads}
    end
  end
end
