defmodule DashboardPhoenix.Mailer do
  @moduledoc """
  Email delivery module for the dashboard application.
  
  Configures and provides email sending capabilities using Swoosh.
  """
  use Swoosh.Mailer, otp_app: :dashboard_phoenix
end
