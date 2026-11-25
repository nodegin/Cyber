// cursor.js: a neon triangle pointer.
//
// A real cursor image (CSS `cursor`), generated here so its colour can follow the HUD
// state (cyan, red on ICE alert). Being the actual cursor, it has zero lag.
// Options: cursor = false (normal system cursor), cursorSize = 1.25 (0.75 .. 2).
(() => {
  "use strict";

  const BODY = [[4, 3], [4, 27], [10.5, 21], [22, 21.5]]; // tip (the hotspot), left foot, notch, wing
  const INNER = [[6.5, 9], [6.5, 21.5], [10, 18], [16, 18.2]];

  function drawPointer(color, accent, r) { // r = device pixels per design unit
    const c = document.createElement("canvas");
    c.width = c.height = Math.round(40 * r);
    const x = c.getContext("2d");
    x.scale(r, r);
    x.lineJoin = "miter";
    const poly = (pts) => {
      x.beginPath();
      pts.forEach(([px, py], i) => (i ? x.lineTo(px, py) : x.moveTo(px, py)));
      x.closePath();
    };
    poly(BODY);
    x.fillStyle = "rgba(3, 6, 14, 0.8)";
    x.fill();
    x.shadowColor = color;                       // glow, then a crisp line on top
    x.strokeStyle = color;
    x.shadowBlur = 8; x.lineWidth = 1.8; x.stroke();
    x.shadowBlur = 2; x.lineWidth = 1.2; x.stroke();
    x.shadowBlur = 0; x.globalAlpha = 0.45; x.lineWidth = 0.8;   // inner circuit line
    poly(INNER);
    x.stroke();
    x.globalAlpha = 1;
    x.shadowBlur = 6; x.fillStyle = color;       // hot core at the tip
    poly([[4, 3], [4, 12], [8.5, 7.8]]);
    x.fill();
    x.shadowBlur = 0; x.fillStyle = "#ffffff";
    poly([[4, 3], [4, 7], [6, 5.2]]);
    x.fill();
    x.shadowColor = accent; x.shadowBlur = 5;    // detached accent tick along the edge
    x.strokeStyle = accent; x.lineWidth = 1.4;
    x.beginPath();
    x.moveTo(13, 7.5);
    x.lineTo(19, 13.5);
    x.stroke();
    return c.toDataURL("image/png");
  }

  class CyberCursor {
    constructor(opts) {
      this.enabled = opts.cursor !== false;
      this.size = Math.min(2, Math.max(0.75, Number(opts.cursorSize) || 1.25));
      if (!this.enabled) return;
      document.documentElement.classList.add("neon-cursor");
      this.setColor("#3cf0ff", "#ff2bd6");
    }

    setColor(color, accent) {
      if (!this.enabled) return;
      const dpr = Math.min(3, Math.max(1, devicePixelRatio || 1));
      const url = drawPointer(color, accent, dpr * this.size);
      const hot = (v) => Math.round(v * this.size);  // the tip, in CSS pixels
      document.documentElement.style.setProperty("--cursor", `-webkit-image-set(url("${url}") ${dpr}x) ${hot(4)} ${hot(3)}, default`);
    }
  }

  window.CyberCursor = CyberCursor;
})();
