// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/sentientwave_automata_web"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

const initProviderForms = () => {
  document.querySelectorAll("[data-provider-form]").forEach(form => {
    if (form.dataset.providerInitialized === "true") return

    const select = form.querySelector("[data-provider-select]")
    const guide = document.querySelector("[data-provider-guide]")

    if (!select || !guide) return

    let catalog = {}

    try {
      catalog = JSON.parse(guide.dataset.providerCatalog || "{}")
    } catch (_error) {
      catalog = {}
    }

    const title = guide.querySelector("[data-provider-guide-title]")
    const summary = guide.querySelector("[data-provider-guide-summary]")
    const family = guide.querySelector("[data-provider-guide-family]")
    const model = guide.querySelector("[data-provider-guide-model]")
    const endpoint = guide.querySelector("[data-provider-guide-endpoint]")
    const auth = guide.querySelector("[data-provider-guide-auth]")
    const tokenHelp = guide.querySelector("[data-provider-guide-token-help]")
    const modelHelp = guide.querySelector("[data-provider-guide-model-help]")
    const endpointHelp = guide.querySelector("[data-provider-guide-endpoint-help]")

    const modelInput = form.querySelector("[data-provider-model-input]")
    const baseUrlInput = form.querySelector("[data-provider-base-url-input]")
    const tokenLabel = form.querySelector("[data-provider-token-label]")
    const tokenCopy = form.querySelector("[data-provider-token-copy]")
    const modelCopy = form.querySelector("[data-provider-model-copy]")
    const baseUrlCopy = form.querySelector("[data-provider-base-url-copy]")
    const editMode = form.dataset.providerMode === "edit"

    const update = () => {
      const provider = (select.value || "local").trim().toLowerCase()
      const setup = catalog[provider] || catalog.local

      if (!setup) return

      if (title) title.textContent = setup.label || provider
      if (summary) summary.textContent = setup.summary || ""
      if (family) family.textContent = setup.family || ""
      if (model) model.textContent = setup.default_model || ""
      if (endpoint) endpoint.textContent = setup.default_base_url_label || ""
      if (auth) auth.textContent = setup.auth_header || ""
      if (tokenHelp) tokenHelp.textContent = setup.token_help || ""
      if (modelHelp) modelHelp.textContent = setup.model_help || ""
      if (endpointHelp) endpointHelp.textContent = setup.endpoint_help || ""

      if (modelInput) {
        modelInput.placeholder = setup.default_model || "Provider default model"
      }

      if (baseUrlInput) {
        baseUrlInput.placeholder = setup.default_base_url || "Leave blank to use provider default"
      }

      if (tokenLabel) {
        const suffix = editMode ? " (leave blank to keep existing)" : " (optional)"
        tokenLabel.textContent = `${setup.token_label || "API Token"}${suffix}`
      }

      if (tokenCopy) {
        tokenCopy.textContent =
          setup.token_help || "Save a provider credential here, or rely on your runtime environment if you prefer."
      }

      if (modelCopy) {
        modelCopy.textContent =
          setup.model_help || "Leave blank to use the selected provider default model."
      }

      if (baseUrlCopy) {
        baseUrlCopy.textContent =
          setup.endpoint_help || "Leave blank to use the selected provider default endpoint."
      }
    }

    select.addEventListener("change", update)
    form.dataset.providerInitialized = "true"
    update()
  })
}

initProviderForms()
window.addEventListener("DOMContentLoaded", initProviderForms)
window.addEventListener("phx:page-loading-stop", initProviderForms)

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
