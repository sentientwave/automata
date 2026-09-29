// Infinite 2D org chart canvas: pan (drag background), zoom (wheel to cursor),
// draggable nodes, edges that follow nodes, click-to-inspect tooltip.

const NODE_W = 210
const NODE_H = 62
const H_SPACING = 300
const V_SPACING = 160
const EDGE_COLOR = "#94a3b8"

// roundRect fallback for older browsers
if (typeof CanvasRenderingContext2D !== "undefined" && !CanvasRenderingContext2D.prototype.roundRect) {
  CanvasRenderingContext2D.prototype.roundRect = function (x, y, w, h, r) {
    r = Math.min(r, w / 2, h / 2)
    this.moveTo(x + r, y)
    this.arcTo(x + w, y, x + w, y + h, r)
    this.arcTo(x + w, y + h, x, y + h, r)
    this.arcTo(x, y + h, x, y, r)
    this.arcTo(x, y, x + w, y, r)
    this.closePath()
    return this
  }
}

const cssVar = (name, fallback) => {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

const initOrgChartCanvas = () => {
  const canvas = document.getElementById("org-chart-canvas")
  if (!canvas || canvas.dataset.orgInitialized === "true") return
  canvas.dataset.orgInitialized = "true"

  let layout
  try {
    layout = JSON.parse(canvas.dataset.orgLayout || "{}")
  } catch (_error) {
    layout = {nodes: [], edges: [], width: 0, height: 0}
  }

  const tooltip = document.getElementById("org-chart-tooltip")
  const wrap = canvas.parentElement
  const resetButton = document.getElementById("org-chart-reset")

  const ctx = canvas.getContext("2d")
  const dpr = window.devicePixelRatio || 1

  const nodes = new Map(layout.nodes.map(n => [n.localpart, {...n, ox: 0, oy: 0}]))
  const edges = layout.edges || []

  // world coordinates: node x is a slot, node y is a depth level
  const worldOf = node => ({
    x: node.x * H_SPACING + (node.ox || 0),
    y: node.y * V_SPACING + (node.oy || 0),
  })

  const camera = {x: 0, y: 0, zoom: 1}
  const fitView = () => {
    const positions = [...nodes.values()].map(worldOf)
    if (positions.length === 0) return
    const minX = Math.min(...positions.map(p => p.x)) - NODE_W
    const maxX = Math.max(...positions.map(p => p.x)) + NODE_W
    const minY = Math.min(...positions.map(p => p.y)) - NODE_H
    const maxY = Math.max(...positions.map(p => p.y)) + NODE_H
    const size = () => ({w: canvas.clientWidth || wrap.clientWidth || 900, h: canvas.clientHeight || 600})
    const {w, h} = size()
    camera.zoom = Math.max(0.04, Math.min(1.2, Math.min(w / (maxX - minX), h / (maxY - minY))))
    camera.x = (minX + maxX) / 2
    camera.y = (minY + maxY) / 2
  }

  const resize = () => {
    const rect = wrap.getBoundingClientRect()
    canvas.width = Math.max(300, rect.width) * dpr
    canvas.height = Math.max(420, rect.height) * dpr
    canvas.style.width = Math.max(300, rect.width) + "px"
    canvas.style.height = Math.max(420, rect.height) + "px"
    draw()
  }

  const toScreen = (wx, wy) => {
    const {w, h} = {w: canvas.width / dpr, h: canvas.height / dpr}
    return {
      x: (wx - camera.x) * camera.zoom + w / 2,
      y: (wy - camera.y) * camera.zoom + h / 2,
    }
  }

  const toWorld = (sx, sy) => {
    const {w, h} = {w: canvas.width / dpr, h: canvas.height / dpr}
    return {
      x: (sx - w / 2) / camera.zoom + camera.x,
      y: (sy - h / 2) / camera.zoom + camera.y,
    }
  }

  const hitNode = (sx, sy) => {
    for (const node of nodes.values()) {
      const p = worldOf(node)
      const s = toScreen(p.x, p.y)
      if (sx >= s.x - NODE_W / 2 && sx <= s.x + NODE_W / 2 && sy >= s.y - NODE_H / 2 && sy <= s.y + NODE_H / 2) {
        return node
      }
    }
    return null
  }

  const colors = () => ({
    nodeBg: cssVar("--sw-bg-card", "#ffffff"),
    nodeBorder: cssVar("--sw-border", "#cbd5e1"),
    text: cssVar("--sw-text", "#0f172a"),
    muted: cssVar("--sw-muted", "#64748b"),
    accent: cssVar("--sw-accent", "#2563eb"),
  })

  const draw = () => {
    const c = colors()
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    const {w, h} = {w: canvas.width / dpr, h: canvas.height / dpr}
    ctx.clearRect(0, 0, w, h)

    // faint grid (infinite feel)
    ctx.strokeStyle = "rgba(148, 163, 184, 0.15)"
    ctx.lineWidth = 1
    const grid = 60 * camera.zoom
    const origin = toScreen(0, 0)
    const startX = ((origin.x % grid) + grid) % grid
    const startY = ((origin.y % grid) + grid) % grid
    for (let gx = startX; gx < w; gx += grid) {
      ctx.beginPath(); ctx.moveTo(gx, 0); ctx.lineTo(gx, h); ctx.stroke()
    }
    for (let gy = startY; gy < h; gy += grid) {
      ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke()
    }

    // edges
    for (const edge of edges) {
      const from = nodes.get(edge.from)
      const to = nodes.get(edge.to)
      if (!from || !to) continue
      const a = worldOf(from)
      const b = worldOf(to)
      const sa = toScreen(a.x, a.y + NODE_H / 2)
      const sb = toScreen(b.x, b.y - NODE_H / 2)
      const midX = (sa.x + sb.x) / 2
      ctx.strokeStyle = EDGE_COLOR
      ctx.lineWidth = 1.5 * camera.zoom
      ctx.beginPath()
      ctx.moveTo(sa.x, sa.y)
      ctx.bezierCurveTo(midX, sa.y, midX, sb.y, sb.x, sb.y)
      ctx.stroke()
    }

    // nodes
    for (const node of nodes.values()) {
      const p = worldOf(node)
      const s = toScreen(p.x, p.y)
      const w2 = NODE_W / 2
      const h2 = NODE_H / 2

      ctx.fillStyle = c.nodeBg
      ctx.strokeStyle = node.reports_to ? c.nodeBorder : c.accent
      ctx.lineWidth = node.reports_to ? 1 : 2.5
      ctx.beginPath()
      ctx.roundRect(s.x - w2, s.y - h2, NODE_W, NODE_H, 10)
      ctx.fill()
      ctx.stroke()

      ctx.fillStyle = c.text
      ctx.font = "600 13px system-ui, sans-serif"
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      const name = node.name.length > 26 ? node.name.slice(0, 25) + "…" : node.name
      ctx.fillText(name, s.x, s.y - 12)

      ctx.fillStyle = c.muted
      ctx.font = "11px system-ui, sans-serif"
      const title = (node.title || "").length > 32 ? (node.title || "").slice(0, 31) + "…" : (node.title || "")
      ctx.fillText(title, s.x, s.y + 5)

      const meta = [node.sex, node.age ? `${node.age} y.o.` : null, node.report_count ? `${node.report_count} reports` : null]
        .filter(Boolean).join(" · ")
      ctx.fillText(meta || "—", s.x, s.y + 20)
    }
  }

  let dragState = null

  canvas.addEventListener("mousedown", event => {
    const rect = canvas.getBoundingClientRect()
    const sx = event.clientX - rect.left
    const sy = event.clientY - rect.top
    const node = hitNode(sx, sy)
    dragState = node
      ? {type: "node", node, startSx: sx, startSy: sy, startOx: node.ox || 0, startOy: node.oy || 0}
      : {type: "pan", startSx: sx, startSy: sy, startCamX: camera.x, startCamY: camera.y}
  })

  window.addEventListener("mousemove", event => {
    if (!dragState) return
    const rect = canvas.getBoundingClientRect()
    const sx = event.clientX - rect.left
    const sy = event.clientY - rect.top

    if (dragState.type === "pan") {
      camera.x = dragState.startCamX - (sx - dragState.startSx) / camera.zoom
      camera.y = dragState.startCamY - (sy - dragState.startSy) / camera.zoom
    } else {
      dragState.node.ox = dragState.startOx + (sx - dragState.startSx) / camera.zoom
      dragState.node.oy = dragState.startOy + (sy - dragState.startSy) / camera.zoom
    }
    draw()
  })

  window.addEventListener("mouseup", () => { dragState = null })

  canvas.addEventListener("wheel", event => {
    event.preventDefault()
    const rect = canvas.getBoundingClientRect()
    const sx = event.clientX - rect.left
    const sy = event.clientY - rect.top
    const before = toWorld(sx, sy)
    camera.zoom = Math.max(0.04, Math.min(3, camera.zoom * (event.deltaY < 0 ? 1.1 : 0.9)))
    const after = toWorld(sx, sy)
    camera.x += before.x - after.x
    camera.y += before.y - after.y
    draw()
  }, {passive: false})

  canvas.addEventListener("click", event => {
    const rect = canvas.getBoundingClientRect()
    const node = hitNode(event.clientX - rect.left, event.clientY - rect.top)
    if (!node || !tooltip) return
    tooltip.querySelector("[data-org-tip-name]").textContent = node.name
    tooltip.querySelector("[data-org-tip-title]").textContent = node.title || ""
    tooltip.querySelector("[data-org-tip-meta]").textContent = [
      node.sex, node.age ? `${node.age} y.o.` : null, node.department,
      node.reports_to ? `reports to: ${node.reports_to}` : "top of org",
      node.report_count ? `${node.report_count} direct reports` : null,
    ].filter(Boolean).join(" · ")
    const link = tooltip.querySelector("[data-org-tip-link]")
    link.href = `/directory/users/${node.localpart}`

    const p = worldOf(node)
    const s = toScreen(p.x, p.y)
    tooltip.style.left = Math.min(s.x + NODE_W / 2 + 8, canvas.clientWidth - 230) + "px"
    tooltip.style.top = Math.max(8, s.y - 30) + "px"
    tooltip.classList.remove("hidden")
  })

  canvas.addEventListener("mousedown", () => { if (tooltip) tooltip.classList.add("hidden") })

  if (resetButton) resetButton.addEventListener("click", () => {
    for (const node of nodes.values()) { node.ox = 0; node.oy = 0 }
    fitView()
    draw()
  })

  window.addEventListener("resize", resize)
  fitView()
  resize()
}

initOrgChartCanvas()
window.addEventListener("DOMContentLoaded", initOrgChartCanvas)
window.addEventListener("phx:page-loading-stop", initOrgChartCanvas)
