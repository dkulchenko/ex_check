defmodule ExCheck.Lock do
  @moduledoc false

  alias ExCheck.Printer

  @escape Enum.map(~c" [~#%&*{}\\:<>?/+|\"]", &<<&1::utf8>>)
  @poll_interval_ms 1_000

  def with_lock(fun, opts \\ []) do
    global? = Keyword.get(opts, :global, false)
    acquire(global?)

    try do
      fun.()
    after
      release(global?)
    end
  end

  def acquire(global? \\ false) do
    path = get_path(global?)
    do_acquire(path, false)
  end

  def release(global? \\ false) do
    path = get_path(global?)
    File.rm(path)
    :ok
  end

  defp do_acquire(path, printed_waiting?) do
    case try_lock(path) do
      :ok ->
        :ok

      {:locked, pid} ->
        if process_alive?(pid) do
          unless printed_waiting? do
            Printer.info([
              :yellow,
              "=> waiting for previous mix check (PID #{pid}) to complete..."
            ])
          end

          Process.sleep(@poll_interval_ms)
          do_acquire(path, true)
        else
          File.rm(path)
          do_acquire(path, printed_waiting?)
        end
    end
  end

  defp try_lock(path) do
    my_pid = System.pid()

    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        IO.write(file, my_pid)
        File.close(file)
        :ok

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, content} ->
            pid = String.trim(content)
            {:locked, pid}

          {:error, :enoent} ->
            try_lock(path)
        end
    end
  end

  defp process_alive?(pid_string) do
    case System.cmd("kill", ["-0", pid_string], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp get_path(true = _global?) do
    Path.join(System.tmp_dir!(), "ex_check.lock")
  end

  defp get_path(false = _global?) do
    app_id = File.cwd!() |> String.replace(@escape, "_") |> String.replace(~r/^_+/, "")
    Path.join(System.tmp_dir!(), "ex_check-lock-#{app_id}.lock")
  end
end
