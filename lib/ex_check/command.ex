defmodule ExCheck.Command do
  @moduledoc false

  @type cancel_signal :: :sigterm
  @type cancel_info :: %{
          optional(:canceled) => boolean(),
          optional(:signal) => cancel_signal() | nil,
          optional(:process_group) => boolean(),
          optional(:os_pid) => non_neg_integer() | nil
        }

  def run(command, opts \\ []) do
    {output, status, duration, _cancel_info} =
      command
      |> async(opts)
      |> await()

    {output, status, duration}
  end

  def async([exec | args], opts) do
    stream_fn = parse_stream_option(opts)
    cd = Keyword.get(opts, :cd, ".")
    {exec_path, args, cancel_info} = maybe_wrap_process_group(exec, args, cd, opts)

    env =
      opts
      |> Keyword.get(:env, %{})
      |> Enum.map(fn {n, v} -> {String.to_charlist(n), String.to_charlist(v)} end)

    spawn_opts = [
      :stream,
      :binary,
      :exit_status,
      :hide,
      :use_stdio,
      :stderr_to_stdout,
      args: args,
      cd: cd,
      env: env
    ]

    Task.async(fn ->
      start_time = DateTime.utc_now()
      port = Port.open({:spawn_executable, exec_path}, spawn_opts)
      os_pid = get_os_pid(port)
      cancel_info = Map.put(cancel_info, :os_pid, os_pid)
      handle_port(port, stream_fn, "", opts[:silenced], start_time, cancel_info)
    end)
  end

  def unsilence(task = %Task{pid: pid}) do
    send(pid, :unsilence)
    task
  end

  def await(task, timeout \\ :infinity) do
    {output, status, stream_fn, silenced, duration, cancel_info} = Task.await(task, timeout)
    if silenced, do: stream_fn.(output)
    {output, status, duration, cancel_info}
  end

  def stop(%Task{} = task) do
    send(task.pid, {:cancel, :sigterm})
    :ok
  catch
    :exit, _ -> :ok
  end

  @ansi_code_regex ~r/(\x1b\[[0-9;]*m)/

  defp parse_stream_option(opts) do
    case Keyword.get(opts, :stream) do
      true ->
        if Keyword.get(opts, :tint) && IO.ANSI.enabled?() do
          fn output ->
            output
            |> String.replace(@ansi_code_regex, "\\1" <> IO.ANSI.faint())
            |> IO.write()
          end
        else
          &IO.write/1
        end

      falsy when falsy in [nil, false] ->
        fn _ -> nil end

      func when is_function(func) ->
        func
    end
  end

  defp resolve_exec_path(exec, cd) do
    cond do
      Path.type(exec) == :absolute -> exec
      File.exists?(Path.join(cd, exec)) -> Path.join(cd, exec) |> Path.expand()
      path_to_exec = System.find_executable(exec) -> path_to_exec
      true -> raise("executable not found: #{exec}")
    end
  end

  defp maybe_wrap_process_group(exec, args, cd, opts) do
    exec_path = resolve_exec_path(exec, cd)

    process_group = Keyword.get(opts, :process_group, false)
    {exec_path, args, %{canceled: false, signal: nil, process_group: process_group, os_pid: nil}}
  end

  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  defp handle_port(port, stream_fn, output, silenced, start_time, cancel_info) do
    receive do
      {^port, {:data, data}} ->
        data =
          if output == "",
            do: String.replace(data, ~r/^\s*/, ""),
            else: data

        unless silenced, do: stream_fn.(data)
        handle_port(port, stream_fn, output <> data, silenced, start_time, cancel_info)

      {^port, {:exit_status, status}} ->
        duration = DateTime.diff(DateTime.utc_now(), start_time)
        {output, status, stream_fn, silenced, duration, cancel_info}

      :unsilence ->
        stream_fn.(output)
        handle_port(port, stream_fn, output, false, start_time, cancel_info)

      {:cancel, :sigterm} ->
        os_pid = cancel_info[:os_pid] || get_os_pid(port)

        cancel_info =
          cancel_info
          |> Map.put(:os_pid, os_pid)
          |> Map.put(:canceled, true)
          |> Map.put(:signal, :sigterm)

        maybe_sigterm_process_group(cancel_info)
        handle_port(port, stream_fn, output, silenced, start_time, cancel_info)
    end
  end

  defp maybe_sigterm_process_group(%{os_pid: os_pid, process_group: process_group})
       when is_integer(os_pid) do
    if process_group do
      tree = process_tree_pids(os_pid)
      children = Enum.reject(tree, &(&1 == os_pid))

      Enum.each(children, fn pid ->
        _ = System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)
      end)

      _ = System.cmd("kill", ["-TERM", "#{os_pid}"], stderr_to_stdout: true)
    else
      _ = System.cmd("kill", ["-TERM", "#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  catch
    _ -> :ok
  end

  defp maybe_sigterm_process_group(_), do: :ok

  defp process_tree_pids(root_pid) when is_integer(root_pid) do
    do_process_tree_pids([root_pid], MapSet.new([root_pid]))
  end

  defp do_process_tree_pids([], acc), do: MapSet.to_list(acc)

  defp do_process_tree_pids([pid | rest], acc) do
    children =
      pid
      |> child_pids()
      |> Enum.reject(&MapSet.member?(acc, &1))

    acc = Enum.reduce(children, acc, &MapSet.put(&2, &1))
    do_process_tree_pids(rest ++ children, acc)
  end

  defp child_pids(parent_pid) when is_integer(parent_pid) do
    with nil <- System.find_executable("pgrep"),
         {out, 0} <- System.cmd("ps", ["-o", "pid=", "--ppid", "#{parent_pid}"], stderr_to_stdout: true) do
      parse_pids(out)
    else
      pgrep when is_binary(pgrep) ->
        case System.cmd(pgrep, ["-P", "#{parent_pid}"], stderr_to_stdout: true) do
          {out, 0} -> parse_pids(out)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp parse_pids(out) when is_binary(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.flat_map(fn str ->
      case Integer.parse(str) do
        {pid, ""} -> [pid]
        _ -> []
      end
    end)
  end
end
