defmodule Mix.Tasks.Grisp.Deploy do
  @moduledoc """
  Deploys a GRiSP application.
  """

  use Mix.Task
  @recursive true

  @shortdoc "Deploys a GRiSP application"

  def run(_args) do
    Mix.Task.run("compile", [])

    header("🐟 Deploying GRiSP application")

    {:ok, _} = Application.ensure_all_started(:grisp_tools)
    config = Mix.Project.config()[:grisp]

    try do
      :grisp_tools.deploy(%{
        project_root: to_charlist(File.cwd!()),
        otp_version_requirement: to_charlist(config[:otp][:version] || "23"),
        platform: platform(config),
        apps: apps(),
        custom_build: false,
        copy: %{
          force: false,
          destination: to_charlist(config[:deploy][:destination] || "tmp/grisp_sd")
        },
        release: %{},
        handlers:
          :grisp_tools.handlers_init(%{
            event: {&event_handler/2, %{}},
            shell: {&shell_handler/3, nil},
            release: {&release_handler/2, nil}
          }),
        scripts: %{
          pre_script: config[:deploy][:pre_script] || :undefined,
          post_script: config[:deploy][:post_script] || :undefined
        }
      })
    catch
      :error, {:otp_version_mismatch, target, current} ->
        Mix.raise(
          "Current Erlang version (#{current}) does not match target" <>
            " Erlang version (#{target})"
        )
    end
  end

  defp event_handler(event, state) do
    debug(event, label: "event")
    {:ok, handle_event(event, state)}
  end

  defp handle_event({:otp_type, hash, :custom_build}, state) do
    header("Using custom OTP (#{short(hash)})")
    state
  end

  defp handle_event({:otp_type, hash, :package}, state) do
    header("Downloading OTP (#{short(hash)})")
    info("Version: #{short(hash)}")
    state
  end

  defp handle_event({:package, {:download_start, size}}, state) do
    IO.write("    0%")
    Map.put(state, :progress, {0, size})
  end

  defp handle_event(
         {:package, {:download_progress, current}},
         %{:progress => {tens, total}} = state
       ) do
    new_tens = round(current / total * 10)

    if new_tens > tens do
      IO.write(" #{new_tens * 10}%")
    end

    %{state | :progress => {new_tens, total}}
  end

  defp handle_event({:package, {:download_complete, _etag}}, state) do
    IO.write(" OK\n")
    state
  end

  defp handle_event({:package, :download_cached}, state) do
    info("Download already cached")
    state
  end

  defp handle_event({:package, {:http_error, other}}, state) do
    warn("Download error: #{inspect(other)}")
    info("Using cached file")
    state
  end

  defp handle_event({:package, {:extract, :up_to_date}}, state) do
    info("Current package up to date")
    state
  end

  defp handle_event({:package, {:extract, {:start, _package}}}, state) do
    info("Extracting package")
    state
  end

  defp handle_event({:package, {:extract_failed, reason}}, _State) do
    fail!("Tar extraction failed: #{inspect(reason)}")
  end

  defp handle_event({:release, {:start, _release}}, state) do
    header("Creating release")
    state
  end

  defp handle_event({:release, {:done, release}}, state) do
    info("Release complete: #{release.name}-#{release.version}")
    state
  end

  defp handle_event({:deployment, :init}, state) do
    header("Deploying")
    state
  end

  defp handle_event({:deployment, :script, name, {:run, _script}}, state) do
    info("Running #{name}")
    state
  end

  defp handle_event({:deployment, :script, _name, {:result, _output}}, state) do
    state
  end

  defp handle_event({:deployment, :release, {:copy, _source, _target}}, state) do
    info("Copying release...")
    state
  end

  defp handle_event({:deployment, {:files, {:init, _dest}}}, state) do
    info("Copying files...")
    state
  end

  defp handle_event({:deployment, :files, {:copy_error, {:exists, file}}}, _State) do
    fail!("Destination #{file} already exists (use --force to overwrite)")
  end

  defp handle_event({:deployment, :done}, state) do
    header(IO.ANSI.format(["Deployment ", :green, "succesful", :blue, "!"]))
    state
  end

  defp handle_event(_event, state) do
    state
  end

  defp shell_handler(raw_cmd, opts, state) do
    IO.inspect({raw_cmd, opts, state})
    cmd = raw_cmd |> IO.iodata_to_binary()
    debug(cmd, label: "cmd")

    [cmd | args] = String.split(cmd)
    args = for arg <- args, do: String.trim(arg, "\"")

    opts =
      Keyword.update!(opts, :env, fn env ->
        for {k, v} <- env, do: {List.to_string(k), List.to_string(v)}
      end)

    {result, 0} = System.cmd(cmd, args, opts)
    {{:ok, result}, state}
  end

  defp release_handler(relspec, state) do
    debug(relspec, label: "relspec")

    Process.put(:relspec, relspec)

    Mix.Task.run("release", [])

    spec = Process.get(:spec)

    Process.delete(:relspec)
    Process.delete(:spec)

    {%{
       dir: spec.path |> String.to_charlist(),
       name: spec.name |> to_charlist(),
       version: spec.version |> String.to_charlist()
     }, state}
  end

  # What is the deps key for here?
  @spec apps() :: [{Application.app(), %{dir: charlist(), deps: []}}]
  defp apps do
    old = Mix.env()
    Mix.env(:grisp)
    config = Mix.Project.config()
    apps = Mix.Project.apps_paths() || %{config[:app] => Mix.Project.app_path()}

    all_apps =
      apps
      |> Map.merge(Mix.Project.deps_paths())
      |> Map.to_list()
      |> Enum.map(fn {app, path} ->
        {app, %{dir: to_charlist(path), deps: []}}
      end)

    Mix.env(old)
    all_apps
  end

  defp platform(config) do
    case Keyword.get(config, :platform) do
      nil ->
        case Keyword.get(config, :board) do
          nil ->
            :grisp2

          board ->
            Mix.shell().warn("Configuration key 'board' is deprecated, use 'platform' instead.")
            board
        end

      platform ->
        platform
    end
  end

  defp short(string), do: String.slice(to_string(string), 0..8)

  defp header(message), do: Mix.shell().info(IO.ANSI.format([:blue, "===> ", message]))
  defp info(message), do: Mix.shell().info(message)
  defp warn(message), do: Mix.shell().info(IO.ANSI.format([:yellow, message]))
  defp fail!(message), do: Mix.shell().fail!(message)

  defp debug(message, label: label) when is_binary(message) do
    Mix.debug?() &&
      IO.ANSI.format([:cyan, "mix_grisp[#{label}]: ", message])
      |> IO.puts()
  end

  defp debug(term, opts) do
    debug(inspect(term), opts)
    term
  end
end
