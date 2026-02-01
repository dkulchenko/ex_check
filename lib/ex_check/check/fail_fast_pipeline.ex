defmodule ExCheck.Check.FailFastPipeline do
  @moduledoc false

  def run(pending, opts) do
    throttle_fn = Keyword.fetch!(opts, :throttle_fn)
    start_fn = Keyword.fetch!(opts, :start_fn)
    finish_fn = Keyword.fetch!(opts, :finish_fn)

    halt_fn = Keyword.get(opts, :halt_fn, fn _ -> :cont end)
    cancel_fn = Keyword.get(opts, :cancel_fn, fn _ -> :ok end)
    cancel_timeout_ms = Keyword.get(opts, :cancel_timeout_ms, 1_000)

    display_start_fn = Keyword.get(opts, :display_start_fn, fn _ -> :ok end)
    display_print_fn = Keyword.get(opts, :display_print_fn, fn _ -> :ok end)
    display_finish_fn = Keyword.get(opts, :display_finish_fn, fn _ -> :ok end)
    display_abort_fn = Keyword.get(opts, :display_abort_fn, fn -> :ok end)

    state = %{
      pending: pending,
      running: %{},
      finished: [],
      completed: %{},
      queue: [],
      displaying_ref: nil,
      halted: nil
    }

    loop(
      state,
      %{
        throttle_fn: throttle_fn,
        start_fn: start_fn,
        finish_fn: finish_fn,
        halt_fn: halt_fn,
        cancel_fn: cancel_fn,
        cancel_timeout_ms: cancel_timeout_ms,
        display_start_fn: display_start_fn,
        display_print_fn: display_print_fn,
        display_finish_fn: display_finish_fn,
        display_abort_fn: display_abort_fn
      }
    )
  end

  defp loop(state, fns) do
    state =
      state
      |> maybe_start_next(fns)
      |> maybe_start_display(fns)

    cond do
      state.halted != nil and map_size(state.running) == 0 ->
        {:halted, state.finished, state.pending, [], state.halted.reason}

      state.pending == [] and map_size(state.running) == 0 ->
        {state.finished, []}

      map_size(state.running) == 0 ->
        {state.finished, state.pending}

      state.halted != nil ->
        do_halted_loop(state, fns)

      true ->
        receive do
          {ref, task_result} when is_reference(ref) and is_map_key(state.running, ref) ->
            state
            |> handle_task_result(ref, task_result, fns)
            |> loop(fns)

          {:DOWN, ref, :process, _pid, reason}
          when is_reference(ref) and is_map_key(state.running, ref) ->
            state
            |> handle_task_down(ref, reason, fns)
            |> loop(fns)
        end
    end
  end

  defp do_halted_loop(state, fns) do
    deadline_ms = state.halted.deadline_ms
    remaining_ms = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {ref, task_result} when is_reference(ref) and is_map_key(state.running, ref) ->
        state
        |> handle_task_result(ref, task_result, fns)
        |> loop(fns)

      {:DOWN, ref, :process, _pid, reason} when is_reference(ref) and is_map_key(state.running, ref) ->
        state
        |> handle_task_down(ref, reason, fns)
        |> loop(fns)
    after
      remaining_ms ->
        timed_out_payloads =
          Enum.map(state.running, fn {_ref, entry} ->
            Process.demonitor(entry.task.ref, [:flush])
            _ = Task.shutdown(entry.task, :brutal_kill)
            entry.payload
          end)

        _ = fns.display_abort_fn.()
        {:halted, state.finished, state.pending, timed_out_payloads, state.halted.reason}
    end
  end

  defp maybe_start_next(%{halted: halted} = state, _fns) when not is_nil(halted), do: state

  defp maybe_start_next(state, fns) do
    running_payloads =
      Enum.map(state.running, fn {_ref, entry} -> entry.payload end)

    selected = fns.throttle_fn.(state.pending, running_payloads, state.finished)

    {pending, running, queue} =
      Enum.reduce(selected, {state.pending, state.running, state.queue}, fn payload,
                                                                      {pending, running, queue} ->
        running_payload = fns.start_fn.(payload)
        task = extract_task!(running_payload)

        entry = %{
          payload: payload,
          running_payload: running_payload,
          task: task
        }

        {pending -- [payload], Map.put(running, task.ref, entry), queue ++ [task.ref]}
      end)

    %{state | pending: pending, running: running, queue: queue}
  end

  defp handle_task_result(state, ref, task_result, fns) do
    {entry, running} = Map.pop(state.running, ref)
    Process.demonitor(entry.task.ref, [:flush])

    result = fns.finish_fn.(entry.running_payload, task_result)

    state =
      state
      |> Map.put(:running, running)
      |> Map.update!(:finished, &(&1 ++ [result]))
      |> maybe_halt_on(result, ref, fns)
      |> maybe_mark_completed(ref, entry, task_result, result, fns)
      |> maybe_start_display(fns)

    state
  end

  defp handle_task_down(state, ref, reason, fns) do
    {entry, running} = Map.pop(state.running, ref)
    Process.demonitor(entry.task.ref, [:flush])

    result = fns.finish_fn.(entry.running_payload, {:down, reason})

    state =
      state
      |> Map.put(:running, running)
      |> Map.update!(:finished, &(&1 ++ [result]))
      |> maybe_halt_on(result, ref, fns)
      |> maybe_mark_completed(ref, entry, {:down, reason}, result, fns)
      |> maybe_start_display(fns)

    state
  end

  defp maybe_mark_completed(state, ref, entry, task_result, result, fns) do
    if state.displaying_ref == ref do
      output = output_from_task_result(task_result)

      _ = fns.display_print_fn.(task_result)
      _ = fns.display_finish_fn.(output)

      queue = drop_queue_head(state.queue, ref)

      state = %{state | displaying_ref: nil, queue: queue}

      if state.halted != nil and ref == state.halted.failed_ref do
        halted = Map.put(state.halted, :failed_ref_displayed, true)
        %{state | halted: halted}
      else
        state
      end
    else
      completed_entry = Map.merge(entry, %{task_result: task_result, result: result})
      completed = Map.put(state.completed, ref, completed_entry)
      %{state | completed: completed}
    end
  end

  defp maybe_halt_on(state, result, ref, fns) do
    if state.halted == nil do
      case fns.halt_fn.(result) do
        :cont ->
          state

        {:halt, reason} ->
          Enum.each(state.running, fn {_ref, entry} ->
            fns.cancel_fn.(entry.running_payload)
          end)

          halted = %{
            reason: reason,
            failed_ref: ref,
            failed_ref_displayed: false,
            deadline_ms: System.monotonic_time(:millisecond) + fns.cancel_timeout_ms
          }

          %{state | halted: halted}
      end
    else
      state
    end
  end

  defp maybe_start_display(state, fns) do
    cond do
      state.displaying_ref != nil ->
        state

      state.halted != nil and state.halted.failed_ref_displayed == true ->
        state

      state.queue == [] ->
        state

      true ->
        ref = hd(state.queue)

        cond do
          entry = Map.get(state.running, ref) ->
            _ = fns.display_start_fn.(entry.running_payload)
            %{state | displaying_ref: ref}

          entry = Map.get(state.completed, ref) ->
            _ = fns.display_start_fn.(entry.running_payload)

            output = output_from_task_result(entry.task_result)
            _ = fns.display_print_fn.(entry.task_result)
            _ = fns.display_finish_fn.(output)

            completed = Map.delete(state.completed, ref)
            queue = tl(state.queue)

            state = %{state | completed: completed, queue: queue}

            state =
              if state.halted != nil and ref == state.halted.failed_ref do
                halted = Map.put(state.halted, :failed_ref_displayed, true)
                %{state | halted: halted}
              else
                state
              end

            maybe_start_display(state, fns)

          true ->
            %{state | queue: tl(state.queue)} |> maybe_start_display(fns)
        end
    end
  end

  defp output_from_task_result({output, _code, _stream_fn, _silenced, _duration, _cancel_info})
       when is_binary(output),
       do: output

  defp output_from_task_result({:down, _reason}), do: ""
  defp output_from_task_result(_), do: ""

  defp drop_queue_head([ref | rest], ref), do: rest
  defp drop_queue_head(queue, _ref), do: queue

  defp extract_task!({:running, {_, _, _}, %Task{} = task}), do: task
  defp extract_task!(other), do: raise("unexpected running payload: #{inspect(other)}")
end
