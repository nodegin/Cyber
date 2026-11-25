// sfx.js: interface sounds, synthesized with Web Audio (no audio files).
// Turn off with  sounds = false  under [theme_options.cyberpunk] in /etc/canvasgreet/config.toml.
(() => {
  "use strict";

  class Sfx {
    constructor(enabled, volume) {
      this.enabled = enabled;
      this.volume = volume;
      this.ctx = null;
    }

    get audio() {
      if (!this.enabled) return null;
      if (!this.ctx) {
        try {
          this.ctx = new AudioContext();
          this.out = this.ctx.createGain();
          this.out.gain.value = this.volume;
          this.out.connect(this.ctx.destination);
        } catch (e) {
          this.enabled = false;
          return null;
        }
      }
      if (this.ctx.state === "suspended") this.ctx.resume();
      return this.ctx;
    }

    tone(type, f0, f1, dur, gain, delay = 0) {
      const ctx = this.audio;
      if (!ctx) return;
      const t = ctx.currentTime + delay;
      const o = ctx.createOscillator(), g = ctx.createGain();
      o.type = type;
      o.frequency.setValueAtTime(f0, t);
      if (f1 !== f0) o.frequency.exponentialRampToValueAtTime(f1, t + dur);
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(gain, t + 0.004);
      g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      o.connect(g).connect(this.out);
      o.start(t);
      o.stop(t + dur + 0.02);
    }

    noise(dur, gain, freq = 3000, delay = 0) {
      const ctx = this.audio;
      if (!ctx) return;
      const t = ctx.currentTime + delay;
      const buf = ctx.createBuffer(1, Math.ceil(ctx.sampleRate * dur), ctx.sampleRate);
      const d = buf.getChannelData(0);
      for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
      const src = ctx.createBufferSource(), bp = ctx.createBiquadFilter(), g = ctx.createGain();
      src.buffer = buf;
      bp.type = "bandpass";
      bp.frequency.value = freq;
      bp.Q.value = 1.2;
      g.gain.setValueAtTime(gain, t);
      g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      src.connect(bp).connect(g).connect(this.out);
      src.start(t);
    }

    key() { this.tone("square", 1900 + Math.random() * 500, 1700, 0.028, 0.035); }
    erase() { this.tone("square", 900, 700, 0.03, 0.03); }
    tick() { this.tone("sine", 2600, 2600, 0.02, 0.025); }
    select() { this.tone("triangle", 1200, 1600, 0.06, 0.05); }
    glitch() { this.noise(0.09, 0.05, 2400 + Math.random() * 2000); }
    error() {
      this.noise(0.18, 0.08, 900);
      this.tone("sawtooth", 220, 140, 0.16, 0.06);
      this.tone("sawtooth", 180, 110, 0.2, 0.06, 0.17);
    }
    granted() {
      [880, 1320, 1760].forEach((f, i) => this.tone("triangle", f, f, 0.12, 0.06, i * 0.07));
    }
    boot() {
      this.tone("sine", 55, 110, 0.7, 0.08);
      this.noise(0.25, 0.03, 5000, 0.05);
    }
    powerDown() {
      this.tone("sine", 600, 40, 0.45, 0.07);
    }
  }

  window.CyberSfx = Sfx;
})();
