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
import {hooks as colocatedHooks} from "phoenix-colocated/dashboard_phoenix"
import topbar from "../vendor/topbar"

// Custom hooks
import { RelationshipGraph } from "./relationship_graph"

const Hooks = {
  ScrollBottom: {
    mounted() {
      this.scrollToBottom()
    },
    updated() {
      this.scrollToBottom()
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    }
  },
  RelationshipGraph: RelationshipGraph,
  PanelState: {
    mounted() {
      // Load saved panel states from localStorage and send to LiveView
      const saved = localStorage.getItem("systematic:panels")
      if (saved) {
        try {
          const panelState = JSON.parse(saved)
          this.pushEvent("restore_panel_state", { panels: panelState })
        } catch (e) {
          console.error("Failed to parse panel state:", e)
        }
      }
      
      // Load saved model selections from localStorage and send to LiveView
      const savedModels = localStorage.getItem("systematic:models")
      if (savedModels) {
        try {
          const modelState = JSON.parse(savedModels)
          this.pushEvent("restore_model_selections", modelState)
        } catch (e) {
          console.error("Failed to parse model selections:", e)
        }
      }
      
      // Listen for save events from LiveView
      this.handleEvent("save_panel_state", ({ panels }) => {
        localStorage.setItem("systematic:panels", JSON.stringify(panels))
      })
      
      this.handleEvent("save_model_selections", ({ models }) => {
        localStorage.setItem("systematic:models", JSON.stringify(models))
      })
    }
  },
  ThemeToggle: {
    mounted() {
      this.updateIcon()
      
      // Handle click to toggle theme
      this.el.addEventListener("click", () => {
        const html = document.documentElement
        const current = html.getAttribute("data-theme") || "dark"
        const next = current === "dark" ? "light" : "dark"
        html.setAttribute("data-theme", next)
        localStorage.setItem("phx:theme", next)
        this.updateIcon()
      })
      
      // Listen for changes from other tabs
      window.addEventListener("storage", (e) => {
        if (e.key === "phx:theme") this.updateIcon()
      })
    },
    updated() {
      this.updateIcon()
    },
    updateIcon() {
      const theme = localStorage.getItem("phx:theme") || "dark"
      const isDark = theme === "dark"
      
      // Update icons visibility
      const sunIcon = this.el.querySelector(".sun-icon")
      const moonIcon = this.el.querySelector(".moon-icon")
      if (sunIcon) sunIcon.style.display = isDark ? "block" : "none"
      if (moonIcon) moonIcon.style.display = isDark ? "none" : "block"
    }
  },
  CopyToClipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        const text = this.el.dataset.copy
        if (text) {
          navigator.clipboard.writeText(text).then(() => {
            // Flash visual feedback
            const originalBg = this.el.style.backgroundColor
            this.el.style.backgroundColor = "rgba(34, 197, 94, 0.3)"
            setTimeout(() => {
              this.el.style.backgroundColor = originalBg
            }, 200)
          }).catch(err => {
            console.error("Failed to copy:", err)
          })
        }
      })
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
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
    window.addEventListener("keyup", e => keyDown = null)
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

