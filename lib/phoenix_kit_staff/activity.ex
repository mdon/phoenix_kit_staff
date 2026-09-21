defmodule PhoenixKitStaff.Activity do
  @moduledoc """
  The staff module's activity log: `PhoenixKit.Activity.log/3` under the
  `"staff"` module key. Never crashes the caller — core logs a failure and
  returns it as `{:error, _}`.
  """

  @module "staff"

  @doc "Logs a staff activity entry. Options as `PhoenixKit.Activity.log/3`."
  @spec log(String.t(), keyword()) :: {:ok, struct()} | {:error, any()}
  def log(action, opts) when is_binary(action) and is_list(opts),
    do: PhoenixKit.Activity.log(@module, action, opts)

  @doc "The acting user's uuid — see `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t() | map() | nil) :: String.t() | nil
  defdelegate actor_uuid(source), to: PhoenixKitWeb.Actor, as: :uuid
end
