defmodule SentientwaveAutomataWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use SentientwaveAutomataWeb, :html

  alias SentientwaveAutomataWeb.Layouts

  attr :flash, :map, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: ""
  attr :status, :map, required: true
  attr :admin_user, :string, required: true
  attr :nav, :list, required: true
  slot :inner_block, required: true

  def admin_shell(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div class="sw-admin-shell">
      <aside class="sw-sidebar">
        <div class="sw-brand">
          <p class="sw-brand-kicker">SentientWave Automata</p>
          <h2 class="sw-brand-title">{@status.company_name}</h2>
          <p class="sw-brand-subtitle">{@status.group_name}</p>
        </div>

        <nav class="sw-nav" aria-label="Admin navigation">
          <%= for item <- @nav do %>
            <a href={item.href} class={["sw-nav-link", item.active && "is-active"]}>
              {item.label}
            </a>
          <% end %>
        </nav>

        <div class="sw-sidebar-meta">
          <p>Admin: <strong>{@admin_user}</strong></p>
          <p>Source: <strong>{@status.source}</strong></p>
          <p>Homeserver: <strong>{@status.homeserver_domain}</strong></p>
        </div>

        <div class="sw-sidebar-theme">
          <p class="sw-sidebar-section-title">Appearance</p>
          <Layouts.theme_toggle />
        </div>

        <form action={~p"/logout"} method="post" class="sw-sidebar-logout">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="_method" value="delete" />
          <button type="submit" class="sw-btn sw-btn-ghost sw-btn-block">Sign Out</button>
        </form>
      </aside>

      <main class="sw-main">
        <header class="sw-page-header">
          <div>
            <p class="sw-page-kicker">Internal Admin Console</p>
            <h1 class="sw-page-title">{@title}</h1>
            <p :if={@subtitle != ""} class="sw-page-subtitle">{@subtitle}</p>
          </div>

          <div class="sw-status-row">
            <span class={["sw-pill", service_class(@status.services.automata)]}>
              Automata: {@status.services.automata}
            </span>
            <span class={["sw-pill", service_class(@status.services.matrix)]}>
              Matrix: {@status.services.matrix}
            </span>
            <span class={["sw-pill", service_class(@status.services.temporal_ui)]}>
              Temporal: {@status.services.temporal_ui}
            </span>
          </div>
        </header>

        <section class="sw-main-content">
          {render_slot(@inner_block)}
        </section>
      </main>
    </div>
    """
  end

  defp service_class(status) when is_binary(status) do
    cond do
      String.starts_with?(status, "ok") -> "is-ok"
      status == "skipped" -> "is-neutral"
      true -> "is-issue"
    end
  end

  embed_templates "page_html/*"
end
