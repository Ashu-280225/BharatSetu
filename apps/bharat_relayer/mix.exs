defmodule BharatRelayer.MixProject do
  use Mix.Project

  def project do
    [
      app: :bharat_relayer,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {BharatRelayer.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:bharat_data, in_umbrella: true},
      {:bharat_adapters, in_umbrella: true},
      {:bharat_core, in_umbrella: true},
      {:b58, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
