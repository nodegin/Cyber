// player.js: audio engine and visuals for the "music" theme.
//
// Track 1 is "Aurora", a generative ambient piece synthesized live with WebAudio,
// so the theme has music without shipping any audio files. Audio files you put
// in tracks/ are appended ("Artist - Title.mp3"; an image with the same name, or
// cover.jpg, is used as the cover art).
//
// Performance notes for weak GPUs: the background is drawn at 1/10 resolution and
// scaled up by the compositor (which blurs it for free), the visualizer is a single
// path fill per frame, and nothing here uses CSS filters on full-screen layers.
(() => {
  "use strict";

  const AUDIO_EXT = /\.(mp3|ogg|oga|opus|flac|wav|m4a|aac|webm)$/i;
  const IMAGE_EXT = /\.(jpe?g|png|webp|avif|gif)$/i;
  const mtof = (m) => 440 * 2 ** ((m - 69) / 12);
  const hsl = (h, s, l, a = 1) => `hsl(${((h % 360) + 360) % 360} ${s}% ${l}% / ${a})`;

  // ------------------------------------------------------------ palettes
  const hashHue = (str) => [...str].reduce((h, c) => (h * 31 + c.codePointAt(0)) >>> 0, 7) % 360;
  const paletteFromHue = (h) => ({ h1: h, h2: h + 48, h3: h - 70 });

  async function paletteFromImage(url) {
    const img = new Image();
    img.src = url;
    await img.decode();
    const c = document.createElement("canvas");
    c.width = c.height = 24;
    const x = c.getContext("2d", { willReadFrequently: true });
    x.drawImage(img, 0, 0, 24, 24);
    const d = x.getImageData(0, 0, 24, 24).data;
    const bins = new Float32Array(12);
    for (let i = 0; i < d.length; i += 4) {
      const r = d[i] / 255, g = d[i + 1] / 255, b = d[i + 2] / 255;
      const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, delta = max - min;
      if (delta < 0.08 || l < 0.12 || l > 0.9) continue;
      const s = delta / (1 - Math.abs(2 * l - 1));
      let h = max === r ? ((g - b) / delta) % 6 : max === g ? (b - r) / delta + 2 : (r - g) / delta + 4;
      bins[Math.floor((((h * 60) % 360) + 360) % 360 / 30)] += s;
    }
    const top = [...bins.keys()].sort((a, b) => bins[b] - bins[a]).filter((i) => bins[i] > 0);
    if (!top.length) throw new Error("no colour");
    const hue = (i) => i * 30 + 15;
    return { h1: hue(top[0]), h2: hue(top[1] ?? top[0]) + 20, h3: hue(top[2] ?? top[0]) - 40 };
  }

  // ------------------------------------------------------------ "Aurora" generative synth
  const CHORDS = [
    { name: "Dmaj9", notes: [50, 57, 61, 64, 66], hue: 228 },
    { name: "Bm9", notes: [47, 54, 57, 61, 62], hue: 276 },
    { name: "Gmaj7", notes: [43, 50, 54, 57, 61], hue: 322 },
    { name: "A6/9", notes: [45, 52, 54, 59, 61], hue: 186 },
  ];
  const BAR = 8; // seconds per chord

  class Aurora {
    constructor(ctx, destination) {
      this.ctx = ctx;
      this.out = ctx.createGain();
      this.out.gain.value = 0;
      this.out.connect(destination);

      // Pad: shared low-pass with a slow LFO on the cutoff.
      this.padFilter = ctx.createBiquadFilter();
      this.padFilter.type = "lowpass";
      this.padFilter.frequency.value = 1100;
      this.padFilter.Q.value = 0.6;
      const lfo = ctx.createOscillator();
      const lfoDepth = ctx.createGain();
      lfo.frequency.value = 0.05;
      lfoDepth.gain.value = 520;
      lfo.connect(lfoDepth).connect(this.padFilter.frequency);
      lfo.start();

      // Space: a damped feedback echo stands in for reverb (cheap on CPU).
      this.send = ctx.createGain();
      const delay = ctx.createDelay(2);
      delay.delayTime.value = 0.375;
      const feedback = ctx.createGain();
      feedback.gain.value = 0.42;
      const damp = ctx.createBiquadFilter();
      damp.type = "lowpass";
      damp.frequency.value = 2200;
      const wet = ctx.createGain();
      wet.gain.value = 0.55;
      this.send.connect(delay);
      delay.connect(damp).connect(feedback).connect(delay);
      damp.connect(wet).connect(this.out);

      const padSend = ctx.createGain();
      padSend.gain.value = 0.25;
      this.padFilter.connect(this.out);
      this.padFilter.connect(padSend).connect(this.send);

      this.bells = ctx.createGain();
      this.bells.connect(this.out);
      this.bells.connect(this.send);

      this.timer = null;
      this.chordIndex = 0;
      this.current = CHORDS[0];
      this.onChord = null;
    }

    start() {
      const t = this.ctx.currentTime;
      this.out.gain.cancelScheduledValues(t);
      this.out.gain.setValueAtTime(this.out.gain.value, t);
      this.out.gain.linearRampToValueAtTime(1, t + 1.5);
      this.nextChord = t + 0.05;
      this.nextNote = t + 1.2;
      if (!this.timer) this.timer = setInterval(() => this.tick(), 100);
      this.tick();
    }

    stop() {
      const t = this.ctx.currentTime;
      this.out.gain.cancelScheduledValues(t);
      this.out.gain.setValueAtTime(this.out.gain.value, t);
      this.out.gain.linearRampToValueAtTime(0, t + 0.6);
      clearInterval(this.timer);
      this.timer = null;
    }

    tick() {
      const horizon = this.ctx.currentTime + 0.4;
      while (this.nextChord < horizon) {
        const chord = CHORDS[this.chordIndex % CHORDS.length];
        this.pad(chord.notes, this.nextChord, BAR);
        const wait = Math.max(0, (this.nextChord - this.ctx.currentTime) * 1000);
        setTimeout(() => this.onChord && this.onChord(chord), wait);
        this.current = chord;
        this.chordIndex++;
        this.nextChord += BAR;
      }
      while (this.nextNote < horizon) {
        if (Math.random() < 0.5) {
          const pool = this.current.notes.slice(1);
          const m = pool[Math.floor(Math.random() * pool.length)] + (Math.random() < 0.65 ? 12 : 24);
          this.bell(m, this.nextNote);
        }
        this.nextNote += Math.random() < 0.25 ? 0.25 : 0.5;
      }
    }

    pad(notes, t, dur) {
      const ctx = this.ctx, end = t + dur + 3;
      for (const m of notes) {
        const g = ctx.createGain();
        g.gain.setValueAtTime(0, t);
        g.gain.linearRampToValueAtTime(0.034, t + 2.5);
        g.gain.setValueAtTime(0.034, t + dur);
        g.gain.linearRampToValueAtTime(0, end);
        g.connect(this.padFilter);
        for (const cents of [-8, 8]) {
          const o = ctx.createOscillator();
          o.type = "sawtooth";
          o.frequency.value = mtof(m);
          o.detune.value = cents;
          o.connect(g);
          o.start(t);
          o.stop(end + 0.05);
        }
      }
      const bass = ctx.createOscillator();
      const bg = ctx.createGain();
      bass.frequency.value = mtof(notes[0] - 12);
      bg.gain.setValueAtTime(0, t);
      bg.gain.linearRampToValueAtTime(0.16, t + 1.2);
      bg.gain.setValueAtTime(0.16, t + dur - 0.5);
      bg.gain.linearRampToValueAtTime(0, t + dur + 0.8);
      bass.connect(bg).connect(this.out);
      bass.start(t);
      bass.stop(t + dur + 1);
    }

    bell(m, t) {
      const ctx = this.ctx, f = mtof(m);
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.055, t + 0.012);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 1.8);
      const pan = ctx.createStereoPanner();
      pan.pan.value = Math.random() * 1.2 - 0.6;
      g.connect(pan).connect(this.bells);
      for (const [ratio, amp] of [[1, 1], [2.01, 0.25], [3.98, 0.07]]) {
        const o = ctx.createOscillator();
        const og = ctx.createGain();
        o.frequency.value = f * ratio;
        og.gain.value = amp;
        o.connect(og).connect(g);
        o.start(t);
        o.stop(t + 1.9);
      }
    }
  }

  // ------------------------------------------------------------ player
  class Player extends EventTarget {
    constructor(audioElement) {
      super();
      this.audio = audioElement;
      this.tracks = [{ kind: "synth", title: "Aurora", artist: "canvasgreet · generative", palette: paletteFromHue(CHORDS[0].hue) }];
      this.index = 0;
      this.playing = false;
      this.volume = 0.6;
      this.liveBase = 0;
      this.liveSince = 0;
      this.audio.addEventListener("ended", () => this.next());
    }

    get current() { return this.tracks[this.index]; }
    emit(type) { this.dispatchEvent(new Event(type)); }

    addFiles(files) {
      const images = new Map(files.filter((f) => IMAGE_EXT.test(f.name))
        .map((f) => [f.name.replace(/\.[^.]+$/, "").toLowerCase(), f.url]));
      const folderCover = images.get("cover") || images.get("folder") || null;
      for (const f of files.filter((f) => AUDIO_EXT.test(f.name))) {
        const base = f.name.replace(/\.[^.]+$/, "");
        const split = base.indexOf(" - ");
        this.tracks.push({
          kind: "file",
          url: f.url,
          artist: split > 0 ? base.slice(0, split).trim() : "Unknown artist",
          title: split > 0 ? base.slice(split + 3).trim() : base,
          cover: images.get(base.toLowerCase()) || folderCover,
          palette: paletteFromHue(hashHue(base)),
        });
      }
    }

    ensureAudio() {
      if (this.ctx) {
        if (this.ctx.state === "suspended") this.ctx.resume();
        return;
      }
      const ctx = (this.ctx = new AudioContext({ latencyHint: "playback" }));
      this.master = ctx.createGain();
      this.master.gain.value = this.volume ** 2;
      const limiter = ctx.createDynamicsCompressor();
      limiter.threshold.value = -10;
      limiter.ratio.value = 4;
      this.analyser = ctx.createAnalyser();
      this.analyser.fftSize = 1024;
      this.analyser.smoothingTimeConstant = 0.78;
      this.freq = new Uint8Array(this.analyser.frequencyBinCount);
      this.master.connect(limiter).connect(this.analyser).connect(ctx.destination);
      this.synth = new Aurora(ctx, this.master);
      this.synth.onChord = (chord) => {
        if (this.current.kind !== "synth" || !this.playing) return;
        this.current.palette = paletteFromHue(chord.hue);
        this.emit("palette");
      };
      ctx.createMediaElementSource(this.audio).connect(this.master);
    }

    async load(i, autoplay = this.playing) {
      this.halt();
      this.index = (i + this.tracks.length) % this.tracks.length;
      const t = this.current;
      this.liveBase = 0;
      if (t.kind === "file") {
        this.audio.src = t.url;
        if (t.cover) t.palette = await paletteFromImage(t.cover).catch(() => t.palette);
      }
      this.emit("track");
      this.emit("palette");
      if (autoplay) this.play();
    }

    halt() {
      if (this.playing && this.current.kind === "synth") this.synth.stop();
      this.audio.pause();
      if (this.playing) this.liveBase += (performance.now() - this.liveSince) / 1000;
      this.playing = false;
    }

    play() {
      if (this.playing) return;
      this.ensureAudio();
      if (this.current.kind === "synth") this.synth.start();
      else this.audio.play().catch((e) => console.error("audio:", e.message));
      this.playing = true;
      this.liveSince = performance.now();
      this.emit("state");
    }

    pause() {
      if (!this.playing) return;
      this.halt();
      this.emit("state");
    }

    toggle() { this.playing ? this.pause() : this.play(); }
    next() { this.load(this.index + 1); }
    prev() {
      if (this.current.kind === "file" && this.audio.currentTime > 3) this.audio.currentTime = 0;
      else this.load(this.index - 1);
    }

    setVolume(v) {
      this.volume = v;
      if (this.master) this.master.gain.setTargetAtTime(v * v, this.ctx.currentTime, 0.05);
    }

    seek(fraction) {
      if (this.current.kind === "file" && Number.isFinite(this.audio.duration)) {
        this.audio.currentTime = fraction * this.audio.duration;
      }
    }

    fadeOut(ms) {
      if (this.master) this.master.gain.setTargetAtTime(0, this.ctx.currentTime, ms / 4000);
    }

    position() {
      if (this.current.kind === "file") {
        return { elapsed: this.audio.currentTime || 0, duration: this.audio.duration || NaN };
      }
      const live = this.liveBase + (this.playing ? (performance.now() - this.liveSince) / 1000 : 0);
      return { elapsed: live, duration: Infinity };
    }

    levels() {
      if (!this.analyser || !this.playing) return null;
      this.analyser.getByteFrequencyData(this.freq);
      return this.freq;
    }
  }

  // ------------------------------------------------------------ background
  const lerpHue = (a, b, k) => a + ((((b - a) % 360) + 540) % 360 - 180) * k;

  class Ambient {
    constructor(canvas) {
      this.canvas = canvas;
      this.ctx = canvas.getContext("2d", { alpha: false });
      this.hues = [228, 276, 158];
      this.target = [...this.hues];
      this.blobs = Array.from({ length: 5 }, (_, i) => ({
        x: Math.random(), y: Math.random(),
        vx: (Math.random() - 0.5) * 0.035, vy: (Math.random() - 0.5) * 0.035,
        r: 0.32 + Math.random() * 0.22, k: i % 3,
      }));
      this.resize();
      addEventListener("resize", () => this.resize());
    }

    resize() {
      this.canvas.width = Math.max(64, Math.round(innerWidth / 10));
      this.canvas.height = Math.max(36, Math.round(innerHeight / 10));
    }

    setPalette(p) { this.target = [p.h1, p.h2, p.h3]; }

    draw(dt, energy) {
      const { width: w, height: h } = this.canvas, x = this.ctx;
      const ease = 1 - Math.exp(-dt * 0.9);
      this.hues = this.hues.map((v, i) => lerpHue(v, this.target[i], ease));
      x.globalCompositeOperation = "source-over";
      x.fillStyle = hsl(this.hues[0], 40, 6);
      x.fillRect(0, 0, w, h);
      x.globalCompositeOperation = "lighter";
      for (const b of this.blobs) {
        b.x += b.vx * dt;
        b.y += b.vy * dt;
        if (b.x < -0.15 || b.x > 1.15) b.vx *= -1;
        if (b.y < -0.15 || b.y > 1.15) b.vy *= -1;
        const R = b.r * Math.max(w, h) * (1 + energy * 0.35);
        const g = x.createRadialGradient(b.x * w, b.y * h, 0, b.x * w, b.y * h, R);
        g.addColorStop(0, hsl(this.hues[b.k], 72, 40, 0.5));
        g.addColorStop(1, hsl(this.hues[b.k], 72, 30, 0));
        x.fillStyle = g;
        x.fillRect(0, 0, w, h);
      }
    }
  }

  // ------------------------------------------------------------ visualizer
  class Visualizer {
    constructor(canvas) {
      this.canvas = canvas;
      this.ctx = canvas.getContext("2d");
      this.resize();
      addEventListener("resize", () => this.resize());
    }

    resize() {
      const r = Math.min(devicePixelRatio || 1, 1.5);
      this.canvas.width = Math.round(this.canvas.clientWidth * r);
      this.canvas.height = Math.round(this.canvas.clientHeight * r);
      const count = Math.max(24, Math.round(this.canvas.clientWidth / 15));
      this.half = Math.ceil(count / 2);
      this.vals = new Float32Array(this.half);
    }

    sample(freq, f) {
      const lo = 2, hi = freq.length * 0.62;
      const idx = lo * (hi / lo) ** f;
      const i = Math.floor(idx);
      const v = ((freq[i] || 0) + (freq[i + 1] || 0) + (freq[i - 1] || 0)) / 3 / 255;
      return Math.min(1, v ** 1.5 * (1 + f * 0.9));
    }

    draw(freq, hues, dt, t) {
      const { width: w, height: h } = this.canvas, x = this.ctx;
      x.clearRect(0, 0, w, h);
      const n = this.half, slot = w / (n * 2), bw = Math.max(2, slot * 0.52);
      for (let i = 0; i < n; i++) {
        const f = i / n;
        const target = freq ? this.sample(freq, f) : 0.04 + 0.12 * Math.sin(t * 0.9 - i * 0.22) ** 2 * (1 - f * 0.6);
        const v = this.vals[i];
        this.vals[i] = target > v ? v + (target - v) * Math.min(1, dt * 22) : Math.max(target, v - dt * 0.9);
      }
      const grad = x.createLinearGradient(0, h, 0, h * 0.15);
      grad.addColorStop(0, hsl(hues[0], 90, 70, 0.95));
      grad.addColorStop(1, hsl(hues[1], 85, 72, 0.35));
      x.fillStyle = grad;
      x.beginPath();
      const cx = w / 2;
      for (let i = 0; i < n; i++) {
        const bh = Math.max(bw, this.vals[i] * h * 0.92);
        const off = (i + 0.5) * slot;
        x.roundRect(cx + off - bw / 2, h - bh, bw, bh, bw / 2);
        x.roundRect(cx - off - bw / 2, h - bh, bw, bh, bw / 2);
      }
      x.fill();
    }
  }

  // ------------------------------------------------------------ generated cover art
  function drawCover(canvas, p) {
    const S = (canvas.width = canvas.height = 640), x = canvas.getContext("2d");
    const bg = x.createLinearGradient(0, 0, S, S);
    bg.addColorStop(0, hsl(p.h1, 70, 22));
    bg.addColorStop(1, hsl(p.h2, 65, 12));
    x.fillStyle = bg;
    x.fillRect(0, 0, S, S);
    x.globalCompositeOperation = "lighter";
    for (let k = 0; k < 6; k++) {
      const hue = [p.h1, p.h2, p.h3][k % 3];
      x.beginPath();
      for (let i = 0; i <= 64; i++) {
        const u = i / 64;
        const y = S * (0.35 + k * 0.07) + Math.sin(u * 6.28 * (1 + k * 0.17) + k) * S * 0.09;
        i ? x.lineTo(u * S, y) : x.moveTo(0, y);
      }
      x.strokeStyle = hsl(hue, 85, 62, 0.16);
      x.lineWidth = S * (0.05 + k * 0.012);
      x.stroke();
    }
    x.globalCompositeOperation = "source-over";
    const glow = x.createRadialGradient(S * 0.72, S * 0.28, 0, S * 0.72, S * 0.28, S * 0.5);
    glow.addColorStop(0, hsl(p.h3, 90, 75, 0.35));
    glow.addColorStop(1, "transparent");
    x.fillStyle = glow;
    x.fillRect(0, 0, S, S);
  }

  window.MusicTheme = { Player, Ambient, Visualizer, drawCover, hsl };
})();
