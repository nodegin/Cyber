// app.js: login UI for the "music" theme. Talks to the greeter through window.greeterReady.
(async () => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const { Player, Ambient, Visualizer, drawCover } = window.MusicTheme;

  // Theme options come from /etc/canvasgreet/config.toml:  [theme_options.music]
  const g = await window.greeterReady;
  const opts = { clock24: true, autoplay: false, volume: 0.6, ...g.info.options };
  document.body.classList.toggle("demo", g.info.demo);

  // Film grain: generated once, static.
  const noise = document.createElement("canvas");
  noise.width = noise.height = 128;
  const nx = noise.getContext("2d"), img = nx.createImageData(128, 128);
  for (let i = 0; i < img.data.length; i += 4) {
    const v = Math.random() * 255;
    img.data.set([v, v, v, 255], i);
  }
  nx.putImageData(img, 0, 0);
  document.body.style.setProperty("--noise", `url(${noise.toDataURL()})`);

  // ---------------------------------------------------------- clock
  const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", hour12: !opts.clock24 });
  const dateFmt = new Intl.DateTimeFormat(undefined, { weekday: "long", month: "long", day: "numeric" });
  const tickClock = () => {
    const d = new Date();
    $("time").textContent = timeFmt.format(d);
    $("date").textContent = dateFmt.format(d);
  };
  tickClock();
  setInterval(tickClock, 1000);
  $("host").textContent = g.info.hostname;

  // ---------------------------------------------------------- power (click twice to confirm)
  const caps = await g.powerCapabilities().catch(() => ({}));
  for (const btn of document.querySelectorAll("[data-power]")) {
    const action = btn.dataset.power;
    if (caps[action] === false) btn.hidden = true;
    let timer = null;
    btn.addEventListener("click", async () => {
      if (!btn.classList.contains("armed")) {
        btn.classList.add("armed");
        timer = setTimeout(() => btn.classList.remove("armed"), 3000);
        return;
      }
      clearTimeout(timer);
      btn.classList.remove("armed");
      if (g.info.demo) {
        setStatus(`Demo: would ${action} now (nothing happens in demo)`, "ok");
        return;
      }
      if (action === "suspend") player.pause();
      else player.fadeOut(300);
      const r = await g.power(action).catch((err) => ({ ok: false, error: err.message }));
      if (!r.ok) {
        player.setVolume(player.volume); // undo the fade
        setStatus(`Couldn't ${action}: ${r.error}`, "error");
      }
    });
  }

  // ---------------------------------------------------------- users
  const users = await g.users();
  let userIndex = Math.max(0, users.findIndex((u) => u.name === g.info.preferredUser));
  const renderUser = () => {
    const u = users[userIndex];
    const av = $("avatar");
    if (!u) {
      $("realName").textContent = "No users found";
      return;
    }
    $("realName").textContent = u.realName;
    av.textContent = u.avatar ? "" : (u.realName || u.name).trim().charAt(0).toUpperCase();
    av.style.backgroundImage = u.avatar ? `url("${u.avatar}")` : "";
    $("switchUser").hidden = users.length < 2;
  };
  $("switchUser").addEventListener("click", () => {
    userIndex = (userIndex + 1) % users.length;
    renderUser();
    $("password").focus();
  });
  renderUser();

  // ---------------------------------------------------------- environments (sessions)
  const ICONS = {
    hypr: '<path d="M12 3.2c3.6 4.3 6 7.6 6 10.4a6 6 0 0 1-12 0c0-2.8 2.4-6.1 6-10.4z"/><path d="M9.2 14.2a2.9 2.9 0 0 0 2.8 2.6"/>',
    cosmic: '<circle cx="12" cy="12" r="3.2"/><ellipse cx="12" cy="12" rx="9.6" ry="4" transform="rotate(-24 12 12)"/>',
    other: '<rect x="3" y="4.5" width="18" height="12" rx="2.2"/><path d="M8.5 20h7M12 16.5V20"/>',
  };
  const iconFor = (s) => {
    const key = `${s.id} ${s.name}`.toLowerCase();
    const shape = key.includes("hypr") ? ICONS.hypr : key.includes("cosmic") ? ICONS.cosmic : ICONS.other;
    return `<svg viewBox="0 0 24 24" class="stroke">${shape}</svg>`;
  };
  const sessions = await g.sessions();
  let sessionIndex = Math.max(0, sessions.findIndex((s) => s.id === g.info.preferredSession));
  const envList = $("envs");
  sessions.forEach((s, i) => {
    const li = document.createElement("li");
    li.className = "env";
    li.setAttribute("role", "option");
    li.innerHTML = `<span class="n">${String(i + 1).padStart(2, "0")}</span>
      <span class="eq" aria-hidden="true"><i></i><i></i><i></i></span>
      <span class="ico">${iconFor(s)}</span>
      <span><div class="name"></div><div class="desc"></div></span>`;
    li.querySelector(".name").textContent = s.name;
    li.querySelector(".desc").textContent = s.comment || s.id;
    li.addEventListener("click", () => selectSession(i));
    envList.append(li);
  });
  const selectSession = (i) => {
    if (!sessions.length) return;
    sessionIndex = (i + sessions.length) % sessions.length;
    [...envList.children].forEach((li, j) => li.setAttribute("aria-selected", String(j === sessionIndex)));
    $("go").setAttribute("aria-label", `Start ${sessions[sessionIndex].name}`);
    if (!pendingPrompt && !busy) setStatus(`Enter your password to start ${sessions[sessionIndex].name}`);
    $("password").focus();
  };

  // ---------------------------------------------------------- status
  const setStatus = (text, kind = "") => {
    const el = $("status");
    el.textContent = text;
    el.className = `status ${kind}`;
  };
  const shake = () => {
    const card = $("card");
    card.classList.remove("shake");
    void card.offsetWidth;
    card.classList.add("shake");
  };

  // ---------------------------------------------------------- login
  let busy = false;
  let pendingPrompt = null;
  const pw = $("password");

  g.on("prompt", (p) => {
    pendingPrompt = p;
    pw.type = p.type === "secret" ? "password" : "text";
    pw.value = "";
    pw.placeholder = p.message.replace(/:\s*$/, "");
    setStatus(p.message);
    pw.focus();
  });
  g.on("message", (m) => setStatus(m.message, m.type === "error" ? "error" : ""));

  $("login").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (pendingPrompt) {
      pendingPrompt = null;
      g.respond(pw.value);
      pw.value = "";
      pw.type = "password";
      pw.placeholder = "Password";
      return;
    }
    if (busy || !users[userIndex] || !sessions.length) return;
    busy = true;
    const session = sessions[sessionIndex];
    setStatus(`Starting ${session.name}…`);
    const result = await g.login(users[userIndex].name, pw.value, session.id).catch((err) => ({ ok: false, error: err.message }));
    busy = false;
    pw.value = "";
    pw.type = "password";
    pw.placeholder = "Password";
    if (result.ok && g.info.demo) {
      setStatus(`Demo: password accepted, ${session.name} would start now`, "ok");
    } else if (result.ok) {
      document.body.classList.add("leaving");
      player.fadeOut(450);
    } else {
      setStatus(result.error || "Login failed", "error");
      shake();
      pw.focus();
    }
  });

  const showCaps = (e) => $("card").classList.toggle("caps", e.getModifierState("CapsLock"));
  pw.addEventListener("keyup", showCaps);
  pw.addEventListener("keydown", (e) => {
    showCaps(e);
    if (e.key === "Escape") {
      if (pendingPrompt) { pendingPrompt = null; g.cancel(); }
      pw.value = "";
    }
  });

  // ---------------------------------------------------------- player
  const player = new Player($("audio"));
  player.addFiles(await g.themeFiles("tracks").catch(() => []));
  const ambient = new Ambient($("ambient"));
  const viz = new Visualizer($("viz"));
  const cover = $("cover"), coverImg = $("coverImg");
  const seek = $("seek"), volume = $("volume");

  const applyPalette = () => {
    const p = player.current.palette;
    const root = document.documentElement.style;
    root.setProperty("--h1", p.h1);
    root.setProperty("--h2", p.h2);
    root.setProperty("--h3", p.h3);
    ambient.setPalette(p);
    if (player.current.kind === "synth" || !player.current.cover) drawCover(cover, p);
  };
  const applyTrack = () => {
    const t = player.current;
    $("title").textContent = t.title;
    $("artist").textContent = t.artist;
    coverImg.hidden = !t.cover;
    if (t.cover) coverImg.src = t.cover;
    seek.disabled = t.kind === "synth";
  };
  player.addEventListener("palette", applyPalette);
  player.addEventListener("track", applyTrack);
  player.addEventListener("state", () => document.body.classList.toggle("playing", player.playing));
  applyTrack();
  applyPalette();

  $("play").addEventListener("click", () => player.toggle());
  $("next").addEventListener("click", () => player.next());
  $("prev").addEventListener("click", () => player.prev());
  const setRangeFill = (el) => el.style.setProperty("--p", `${(el.value / el.max) * 100}%`);
  volume.value = Math.round(opts.volume * 100);
  setRangeFill(volume);
  player.setVolume(opts.volume);
  volume.addEventListener("input", () => { player.setVolume(volume.value / 100); setRangeFill(volume); });
  let seeking = false;
  seek.addEventListener("pointerdown", () => (seeking = true));
  seek.addEventListener("change", () => { player.seek(seek.value / 1000); seeking = false; });

  const BAR_LOOP = 32; // the generative track's chord cycle, in seconds
  const fmt = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
  const updateProgress = () => {
    const { elapsed, duration } = player.position();
    $("elapsed").textContent = fmt(elapsed);
    const dur = $("duration");
    if (duration === Infinity) {
      dur.innerHTML = '<span class="live">LIVE</span>';
      seek.value = (elapsed % BAR_LOOP) / BAR_LOOP * 1000;
    } else {
      dur.textContent = Number.isFinite(duration) ? fmt(duration) : "--:--";
      if (!seeking && Number.isFinite(duration)) seek.value = (elapsed / duration) * 1000;
    }
    setRangeFill(seek);
  };

  // ---------------------------------------------------------- keyboard
  addEventListener("keydown", (e) => {
    const inField = document.activeElement === pw;
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      e.preventDefault();
      selectSession(sessionIndex + (e.key === "ArrowUp" ? -1 : 1));
    } else if (e.key === " " && (!inField || pw.value === "")) {
      e.preventDefault();
      player.toggle();
    } else if (e.key === "MediaPlayPause") player.toggle();
    else if (e.key === "MediaTrackNext") player.next();
    else if (e.key === "MediaTrackPrevious") player.prev();
    else if (!inField && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) pw.focus();
  });

  // ---------------------------------------------------------- render loop
  let last = performance.now(), frameNo = 0;
  const frame = (now) => {
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    const levels = player.levels();
    let energy = 0;
    if (levels) {
      for (let i = 2; i < 24; i++) energy += levels[i];
      energy /= 22 * 255;
    }
    if ((frameNo++ & 1) === 0) ambient.draw(dt * 2, energy); // background at 30 fps is plenty
    viz.draw(levels, ambient.hues, dt, now / 1000);
    if (frameNo % 15 === 0) updateProgress();
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  selectSession(sessionIndex);
  pw.focus();
  if (opts.autoplay) setTimeout(() => player.play(), 400);
})();
