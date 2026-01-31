defmodule DashboardPhoenixWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use DashboardPhoenixWeb, :html

  # Custom 401 page for authentication failures
  def render("401.html", _assigns) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>401 Unauthorized</title>
      <style>
        body { font-family: system-ui, sans-serif; background: #1a1a2e; color: #eee; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
        .container { text-align: center; padding: 2rem; }
        h1 { color: #ef4444; margin-bottom: 1rem; }
        p { color: #9ca3af; margin-bottom: 1.5rem; }
        a { color: #6366f1; text-decoration: none; }
        a:hover { text-decoration: underline; }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>401 Unauthorized</h1>
        <p>Invalid or missing authentication token.</p>
        <a href="/login">Go to login page</a>
      </div>
    </body>
    </html>
    """
  end

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
