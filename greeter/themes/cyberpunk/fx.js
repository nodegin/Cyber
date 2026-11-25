// fx.js: the background. Your wallpaper, run through a WebGL "visor" shader every frame:
// lens warp, chromatic aberration, scanlines, grain, rain, a rolling tracking line,
// glitch bursts and a CRT power on/off. The wallpaper is blurred once on load, so the
// per-frame cost is just three texture reads per pixel (60 fps at 3440x1440 on an iGPU).
(() => {
  "use strict";

  const VERT = `
    attribute vec2 p;
    varying vec2 vUv;
    void main() { vUv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }`;

  const FRAG = `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D uTex;
    uniform vec2 uRes, uTexSize, uFocus, uMouse;
    uniform float uTime, uGlitch, uDistort, uRain, uPower, uDim, uSeed;

    float hash(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }

    // "cover" fit of the image, cropped around uFocus (0..1, image coordinates)
    vec2 cover(vec2 uv) {
      float sa = uRes.x / uRes.y, ta = uTexSize.x / uTexSize.y;
      vec2 s = sa > ta ? vec2(1.0, ta / sa) : vec2(sa / ta, 1.0);
      return (1.0 - s) * vec2(uFocus.x, 1.0 - uFocus.y) + uv * s;
    }
    vec3 img(vec2 uv) { return texture2D(uTex, clamp(cover(uv), 0.001, 0.999)).rgb; }

    void main() {
      vec2 c = vUv - 0.5;
      float r2 = dot(c, c);
      float t = uTime;

      // visor lens: gentle barrel warp, slight zoom so the edges stay filled, mouse parallax
      float k = 0.10 * uDistort;
      vec2 uv = 0.5 + c * (1.0 + k * r2) / (1.0 + k * 0.5) * 0.97 - uMouse * 0.010;

      // glitch: horizontal bands jump sideways
      float bn = hash(vec2(floor(vUv.y * 36.0), floor(t * 24.0)) + uSeed);
      uv.x += (bn - 0.5) * 0.14 * uGlitch * step(0.72, bn);

      // a faint tracking line rolls down the screen
      float roll = 1.0 - fract(t * 0.045);
      float trk = smoothstep(0.010, 0.0, abs(vUv.y - roll));
      uv.x += trk * 0.003 * uDistort;

      // chromatic aberration: grows toward the edges, spikes during glitches
      vec2 ca = c * (0.006 * uDistort + 0.045 * uGlitch);
      vec3 col = vec3(img(uv + ca).r, img(uv).g, img(uv - ca).b);

      col *= 1.0 - uDim;
      col *= mix(1.0, smoothstep(0.95, 0.2, length(c * vec2(1.0, 1.3))), 0.7);

      // rain: three layers of slanted streaks
      if (uRain > 0.0) {
        float aspect = uRes.x / uRes.y;
        for (int i = 0; i < 3; i++) {
          float fi = float(i);
          vec2 p = vec2(vUv.x * aspect, vUv.y) * vec2(55.0 + 40.0 * fi, 9.0 + 4.0 * fi);
          p.y += t * (14.0 + 6.0 * fi);
          p.x += p.y * 0.10;
          vec2 id = floor(p), f = fract(p);
          float h = hash(id + fi * 17.0);
          float x = abs(f.x - (0.2 + 0.6 * fract(h * 13.0)));
          float streak = step(0.9, h) * smoothstep(0.04, 0.0, x) * smoothstep(0.0, 0.7, f.y) * smoothstep(1.0, 0.8, f.y);
          col += vec3(0.62, 0.78, 1.0) * streak * (0.05 + 0.035 * fi) * uRain;
        }
      }

      // scanlines, grain, the tracking line's glow
      col *= 0.92 + 0.08 * sin(gl_FragCoord.y * 1.5708);
      col += (hash(gl_FragCoord.xy + fract(t * 7.0) * 91.7) - 0.5) * 0.04;
      col += trk * vec3(0.02, 0.05, 0.06);

      // glitch tint on some bands
      col = mix(col, col.brg * vec3(1.3, 0.7, 1.4), uGlitch * step(0.88, bn));

      // power on/off with a CRT flicker while it ramps
      float flick = 0.8 + 0.2 * hash(vec2(floor(t * 45.0), 3.0));
      col *= uPower * mix(flick, 1.0, uPower * uPower);
      gl_FragColor = vec4(col, 1.0);
    }`;

  class Visor {
    constructor(canvas, opts) {
      this.canvas = canvas;
      this.opts = opts;
      this.glitchUntil = 0;
      this.glitchAmount = 0;
      this.seed = 0;
      this.power = 0;
      this.powerFrom = 0;
      this.powerTo = 0;
      this.powerStart = 0;
      this.powerMs = 1;
      this.mouse = [0, 0];
      this.mouseTarget = [0, 0];
      const gl = (this.gl = canvas.getContext("webgl", { antialias: false, alpha: false, powerPreference: "high-performance" }));
      if (!gl) throw new Error("WebGL unavailable");

      const shader = (type, src) => {
        const s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
        return s;
      };
      const prog = gl.createProgram();
      gl.attachShader(prog, shader(gl.VERTEX_SHADER, VERT));
      gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
      gl.useProgram(prog);
      this.u = {};
      for (const n of ["uTex", "uRes", "uTexSize", "uFocus", "uMouse", "uTime", "uGlitch", "uDistort", "uRain", "uPower", "uDim", "uSeed"]) {
        this.u[n] = gl.getUniformLocation(prog, n);
      }
      gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(prog, "p");
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

      this.tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, this.tex);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
      for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
                            [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) {
        gl.texParameteri(gl.TEXTURE_2D, k, v);
      }
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array([6, 5, 12]));
      this.texSize = [1, 1];

      this.resize();
      addEventListener("resize", () => this.resize());
      addEventListener("pointermove", (e) => {
        this.mouseTarget = [(e.clientX / innerWidth) * 2 - 1, -((e.clientY / innerHeight) * 2 - 1)];
      });
    }

    resize() {
      const dpr = devicePixelRatio || 1;
      this.canvas.width = Math.round(innerWidth * dpr);
      this.canvas.height = Math.round(innerHeight * dpr);
      this.gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    }

    async setImage(url, blurPx) {
      const im = new Image();
      im.src = url;
      await im.decode();
      const c = document.createElement("canvas");
      c.width = im.naturalWidth;
      c.height = im.naturalHeight;
      const x = c.getContext("2d", { alpha: false });
      if (blurPx > 0) x.filter = `blur(${blurPx}px)`;
      x.drawImage(im, 0, 0);
      const gl = this.gl;
      gl.bindTexture(gl.TEXTURE_2D, this.tex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, c);
      this.texSize = [c.width, c.height];
    }

    glitch(amount = 0.6, ms = 220) {
      const now = performance.now();
      this.glitchAmount = Math.max(amount, now < this.glitchUntil ? this.glitchAmount : 0);
      this.glitchUntil = Math.max(this.glitchUntil, now + ms);
      this.seed = Math.random() * 100;
    }

    powerTo_(target, ms) {
      this.powerFrom = this.power;
      this.powerTo = target;
      this.powerStart = performance.now();
      this.powerMs = Math.max(1, ms);
    }

    frame(now, mouseScale) {
      const gl = this.gl, o = this.opts, u = this.u;
      const k = Math.min(1, (now - this.powerStart) / this.powerMs);
      this.power = this.powerFrom + (this.powerTo - this.powerFrom) * k;
      this.mouse = this.mouse.map((v, i) => v + (this.mouseTarget[i] * mouseScale - v) * 0.06);
      const g = now < this.glitchUntil ? this.glitchAmount * (0.6 + 0.4 * Math.random()) : 0;
      gl.uniform1i(u.uTex, 0);
      gl.uniform2f(u.uRes, this.canvas.width, this.canvas.height);
      gl.uniform2f(u.uTexSize, this.texSize[0], this.texSize[1]);
      gl.uniform2f(u.uFocus, o.focus[0], o.focus[1]);
      gl.uniform2f(u.uMouse, this.mouse[0], this.mouse[1]);
      gl.uniform1f(u.uTime, (now / 1000) % 600);
      gl.uniform1f(u.uGlitch, g);
      gl.uniform1f(u.uDistort, o.distortion);
      gl.uniform1f(u.uRain, o.rain ? 1 : 0);
      gl.uniform1f(u.uPower, this.power);
      gl.uniform1f(u.uDim, o.dim);
      gl.uniform1f(u.uSeed, this.seed);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      return g;
    }
  }

  // Fallback without WebGL: the blurred wallpaper on a plain canvas, no effects.
  class FlatVisor {
    constructor(canvas, opts) {
      this.canvas = canvas;
      this.opts = opts;
      this.image = null;
      addEventListener("resize", () => this.draw());
    }
    async setImage(url, blurPx) {
      const im = new Image();
      im.src = url;
      await im.decode();
      this.image = im;
      this.blur = blurPx;
      this.draw();
    }
    draw() {
      const c = this.canvas, dpr = devicePixelRatio || 1;
      c.width = innerWidth * dpr;
      c.height = innerHeight * dpr;
      const x = c.getContext("2d");
      x.fillStyle = "#06050c";
      x.fillRect(0, 0, c.width, c.height);
      if (!this.image) return;
      const im = this.image, s = Math.max(c.width / im.naturalWidth, c.height / im.naturalHeight);
      const w = im.naturalWidth * s, h = im.naturalHeight * s;
      x.filter = `blur(${this.blur * s}px) brightness(${1 - this.opts.dim})`;
      x.drawImage(im, (c.width - w) * this.opts.focus[0], (c.height - h) * this.opts.focus[1], w, h);
    }
    glitch() {}
    powerTo_() {}
    frame() { return 0; }
  }

  window.CyberFX = {
    create(canvas, opts) {
      try {
        return new Visor(canvas, opts);
      } catch (e) {
        console.error("visor: falling back to a flat background:", e.message);
        const fresh = canvas.cloneNode(); // a canvas that got a WebGL context can't switch to 2D
        canvas.replaceWith(fresh);
        return new FlatVisor(fresh, opts);
      }
    },
  };
})();
