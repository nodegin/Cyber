// app.js: the cyberpunk login HUD. Options: [theme_options.cyberpunk] in /etc/canvasgreet/config.toml
(async () => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const g = await window.greeterReady;

  const opts = {
    wallpaper: "",          // file in this folder; default: the first wallpaper.(png|jpg|webp|avif)
    focus: [0.5, 0.62],     // which part of the wallpaper to keep when cropping (x, y: 0..1)
    blur: 1.2,              // wallpaper blur in image pixels
    dim: 0.28,              // 0..1 darkening behind the HUD
    distortion: 1,          // lens warp + chromatic aberration strength (0 = off)
    rain: true,
    glitch: true,           // random glitch bursts (a wrong password always glitches)
    tilt: 16,               // degrees the side HUD columns are turned toward you
    parallax: true,         // HUD and background follow the mouse a little
    sounds: true,
    volume: 0.35,
    cursor: true,           // neon triangle pointer (false = normal system cursor). Unset: on at
                            // the login screen, off on the lock screen (see below)
    cursorSize: 1.25,       // 0.75 .. 2
    boot: true,             // the short boot log at start
    clock24: true,
    dateFormat: "mdy",      // "mdy" 11.22.26  or "ymd" 26.11.22
    cells: 16,              // passphrase boxes
    operator: "",           // name shown after OPERATOR (default: your account's name)
    ...g.info.options,
  };
  document.body.classList.toggle("demo", g.info.demo);
  document.documentElement.style.setProperty("--tilt", `${opts.tilt}deg`);
  // "lock" = running as canvaslock (the lock screen): one user, the locked session, unlock on success.
  const lockMode = g.info.mode === "lock";
  if (lockMode) {
    $("sessionState").textContent = "SESSION LOCKED";
    $("targetsHead").textContent = "UPLINK // ACTIVE SESSION";
    $("targetsJp").textContent = "接続中";
    $("targetsHint").hidden = true;
  }
  // The lock screen runs inside your session, so its pointer is your own cursor set, the same one
  // as on the desktop; the neon triangle is for the login screen, where no user cursor set is
  // loaded. `cursor = true` or `false` in the config forces one of them for both.
  if (lockMode && !("cursor" in (g.info.options || {}))) opts.cursor = false;
  const sfx = new window.CyberSfx(opts.sounds, opts.volume);
  const cursor = new window.CyberCursor(opts);
  let busy = false;          // a login is in progress
  let pending = null;         // an extra PAM prompt (OTP...) waiting for an answer
  let bootRunning = false, bootSkip = false;

  // ---------------------------------------------------------------- background
  const fx = window.CyberFX.create($("bg"), opts);
  const files = await g.themeFiles("").catch(() => []);
  const wallpaper = opts.wallpaper
    ? files.find((f) => f.name === opts.wallpaper)
    : files.find((f) => /^wallpaper\.(png|jpe?g|webp|avif)$/i.test(f.name));
  if (wallpaper) await fx.setImage(wallpaper.url, opts.blur).catch((e) => console.error("wallpaper:", e.message));

  // ---------------------------------------------------------------- static info
  const up = (s) => String(s || "").toUpperCase();
  // Session/desktop names: upper case, except names that must appear exactly as given (the lock
  // screen's desktop choices, e.g. "end-4/pC").
  const sessionName = (s) => (s && s.verbatim ? String(s.name || "") : up(s && s.name));
  // Put text + a session name + text into an element; the name keeps its own spelling (the CSS
  // upper-cases everything else).
  const fillWithName = (el, before, s, after = "") => {
    const span = document.createElement("span");
    span.textContent = sessionName(s);
    if (s && s.verbatim) span.className = "verbatim";
    el.replaceChildren(before, span, after);
  };
  $("host").textContent = up(g.info.hostname);
  $("kernel").textContent = up(g.info.kernel);
  $("os").textContent = up(g.info.os);

  // ---------------------------------------------------------------- glitch
  const hud = $("hud");
  let glitchTimer = null;
  const glitch = (amount, ms, sound = true) => {
    fx.glitch(amount, ms);
    document.body.classList.add("glitch");
    clearTimeout(glitchTimer);
    glitchTimer = setTimeout(() => document.body.classList.remove("glitch"), ms);
    if (sound) sfx.glitch();
  };

  // ---------------------------------------------------------------- clock
  const pad = (n) => String(n).padStart(2, "0");
  const DAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
  const tickClock = () => {
    const d = new Date();
    let h = d.getHours();
    if (!opts.clock24) h = h % 12 || 12;
    const hm = `${pad(h)}:${pad(d.getMinutes())}`;
    for (const el of document.querySelectorAll(".clock .hh")) el.textContent = pad(h);
    for (const el of document.querySelectorAll(".clock .mm")) el.textContent = pad(d.getMinutes());
    $("sec").textContent = pad(d.getSeconds());
    const [m, day, y] = [pad(d.getMonth() + 1), pad(d.getDate()), pad(d.getFullYear() % 100)];
    $("date").innerHTML = `${opts.dateFormat === "ymd" ? `${y}.${m}.${day}` : `${m}.${day}.${y}`} <span>${DAYS[d.getDay()]}</span>`;
    $("feedClock").textContent = `${hm}:${pad(d.getSeconds())}`;
  };
  tickClock();
  setTimeout(() => { tickClock(); setInterval(tickClock, 1000); }, 1000 - (Date.now() % 1000));

  // ---------------------------------------------------------------- operator (user)
  const users = await g.users();
  let userIndex = Math.max(0, users.findIndex((u) => u.name === g.info.preferredUser));
  const renderOperator = () => {
    const u = users[userIndex];
    $("operator").textContent = u ? up(opts.operator || u.realName || u.name) : "UNKNOWN";
    $("operator").classList.toggle("multi", users.length > 1);
  };
  $("operator").addEventListener("click", () => {
    if (users.length < 2) return;
    userIndex = (userIndex + 1) % users.length;
    sfx.select();
    renderOperator();
  });
  renderOperator();

  // ---------------------------------------------------------------- targets (sessions)
  const sessions = await g.sessions();
  let sessionIndex = Math.max(0, sessions.findIndex((s) => s.id === g.info.preferredSession));
  // Lock screen with several desktops to choose from (canvaslock's lock-choices hook): the one
  // picked here is switched to after unlocking. "last" marks the one that is running.
  const lockChoices = lockMode && sessions.length > 1;
  const activeSession = sessions.find((s) => s.last) || sessions[0];
  if (lockChoices) {
    $("targetsHead").textContent = "UPLINK // DESKTOP SELECT";
    $("targetsJp").textContent = "環境選択";
    $("targetsHint").hidden = false;
  }
  $("envCount").textContent = sessions.length;
  sessions.forEach((s, i) => {
    const li = document.createElement("li");
    li.className = "target";
    li.setAttribute("role", "option");
    li.innerHTML = `<span class="idx">${pad(i + 1)}</span><span class="name"></span><span class="tag"></span><span class="desc"></span>`;
    li.querySelector(".name").textContent = sessionName(s);
    li.querySelector(".name").classList.toggle("verbatim", !!s.verbatim);
    li.querySelector(".tag").textContent = lockMode ? (s.last ? "ACTIVE" : "SWITCH") : s.last ? "LAST" : "";
    li.querySelector(".desc").textContent = s.comment || s.id;
    li.addEventListener("click", () => selectSession(i, true));
    $("targets").append(li);
  });
  const selectSession = (i, sound) => {
    if (!sessions.length) return;
    sessionIndex = (i + sessions.length) % sessions.length;
    [...$("targets").children].forEach((li, j) => li.setAttribute("aria-selected", String(j === sessionIndex)));
    const picked = sessions[sessionIndex];
    $("uplink").textContent = sessionName(picked);
    $("uplink").classList.toggle("verbatim", !!picked.verbatim);
    if (!busy && !pending) {
      setStatus(!lockMode ? `ENTER PASSPHRASE TO UPLINK // ${sessionName(picked)}`
        : picked.last ? "ENTER PASSPHRASE TO RESUME SESSION"
          : "ENTER PASSPHRASE TO SWITCH // ", "", lockMode && !picked.last ? picked : null);
    }
    if (sound) sfx.select();
    pw.focus();
  };

  // ---------------------------------------------------------------- toast + ICE state
  const toast = (title, sub, alert = false, session = null) => {
    const t = $("toast");
    $("toastTitle").textContent = title;
    if (session) fillWithName($("toastSub"), "", session, sub);
    else $("toastSub").textContent = sub;
    t.classList.toggle("alert", alert);
    t.style.animation = "none";
    void t.offsetWidth;
    t.style.animation = "";
  };
  let failed = 0;
  let cursorAlert = false;
  const updateIce = () => {
    const alert = failed >= 3;
    document.body.classList.toggle("alert", alert);
    if (alert !== cursorAlert) {
      cursorAlert = alert;
      cursor.setColor(alert ? "#ff3d6e" : "#3cf0ff", alert ? "#ffb547" : "#ff2bd6");
    }
    $("failed").textContent = `FAILED ${failed}`;
    $("failed").classList.toggle("hot", failed > 0);
    $("iceState").textContent = alert ? "ICE ALERT" : "ICE ACTIVE";
    $("jpState").textContent = alert ? "侵入検知 // 防壁警戒中" : lockMode ? "セッション停止 // 防壁稼働中" : "システム待機 // 防壁稼働中";
    $("iceFoot").textContent = alert ? "ICE ENGAGED" : "ICE NOMINAL";
    $("iceFoot").className = alert ? "red" : "";
  };

  // ---------------------------------------------------------------- passphrase cells
  const pw = $("pw");
  const N = Math.max(6, Math.min(32, opts.cells | 0 || 16));
  const cells = Array.from({ length: N }, () => {
    const c = document.createElement("div");
    c.className = "cell";
    $("cells").append(c);
    return c;
  });
  const more = document.createElement("span");
  more.className = "more";
  $("cells").append(more);
  const GLYPHS = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉ0123456789ABCDEF";
  let lastLen = 0;
  const renderCells = (sound = true) => {
    const len = [...pw.value].length;
    const focused = document.activeElement === pw;
    cells.forEach((c, i) => {
      c.classList.toggle("filled", i < len);
      c.classList.toggle("cursor", focused && i === len);
    });
    more.textContent = len > N ? `+${len - N}` : "";
    if (len > lastLen && len <= N) {
      const c = cells[len - 1];
      c.classList.add("fresh");
      c.textContent = GLYPHS[(Math.random() * GLYPHS.length) | 0];
      setTimeout(() => { c.classList.remove("fresh"); c.textContent = ""; }, 140);
    }
    if (sound && len > lastLen) sfx.key();
    else if (sound && len < lastLen) sfx.erase();
    lastLen = len;
  };
  pw.addEventListener("input", () => renderCells());
  pw.addEventListener("focus", () => renderCells(false));
  pw.addEventListener("blur", () => { renderCells(false); setTimeout(() => pw.focus(), 0); });
  addEventListener("pointerdown", () => setTimeout(() => pw.focus(), 0));
  const showCaps = (e) => { $("caps").hidden = !e.getModifierState("CapsLock"); };
  pw.addEventListener("keydown", showCaps);
  pw.addEventListener("keyup", showCaps);

  const setStatus = (text, kind = "", session = null) => {
    if (session) fillWithName($("status"), text, session);
    else $("status").textContent = text;
    $("status").className = `auth-status ${kind === "err" ? "err" : kind === "ok" ? "ok" : ""}`;
  };

  // ---------------------------------------------------------------- login
  const auth = $("auth");

  // chamfered border: same 18px cut as the panel's clip-path, cyan accents on the two cut corners
  const drawBorder = () => {
    const w = auth.offsetWidth, h = auth.offsetHeight, c = 18, a = 46;
    const svg = $("authBorder");
    svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
    svg.innerHTML =
      `<path class="frame-line" d="M0.5 0.5 H${w - c} L${w - 0.5} ${c} V${h - 0.5} H${c} L0.5 ${h - c} Z"/>` +
      `<path class="accent" d="M${w - c - a} 1 H${w - c} L${w - 1} ${c} V${c + a}"/>` +
      `<path class="accent" d="M1 ${h - c - a} V${h - c} L${c} ${h - 1} H${c + a}"/>`;
  };
  new ResizeObserver(drawBorder).observe(auth);

  g.on("prompt", (p) => {
    pending = p;
    pw.value = "";
    renderCells(false);
    setStatus(up(p.message.replace(/:\s*$/, "")), "ok");
  });
  g.on("message", (m) => setStatus(up(m.message), m.type === "error" ? "err" : ""));

  const restore = () => {
    document.body.classList.remove("leaving");
    fx.powerTo_(1, 500);
    selectSession(sessionIndex);
  };
  const leave = (demo) => {
    document.body.classList.add("leaving");
    fx.powerTo_(0, 380);
    sfx.powerDown();
    if (demo) setTimeout(restore, 1400);
  };

  auth.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (pending) {
      pending = null;
      g.respond(pw.value);
      pw.value = "";
      renderCells(false);
      setStatus("VERIFYING // 照合中");
      return;
    }
    if (busy || !users[userIndex] || !sessions.length) return;
    busy = true;
    auth.classList.add("busy");
    const session = sessions[sessionIndex];
    setStatus("AUTHENTICATING // 認証中");
    const result = await g.login(users[userIndex].name, pw.value, session.id)
      .catch((err) => ({ ok: false, error: err.message }));
    auth.classList.remove("busy");
    busy = false;
    pw.value = "";
    renderCells(false);

    if (result.ok) {
      sfx.granted();
      if (lockMode && !session.last) {
        setStatus("ACCESS GRANTED // SWITCHING TO ", "ok", session);
        toast("DESKTOP SWITCH", " // 切替", false, session);
      } else if (lockMode) {
        setStatus("ACCESS GRANTED // SESSION RESUMED", "ok");
        toast("SESSION RESUMED", " // 再開", false, session);
      } else {
        setStatus(`ACCESS GRANTED // UPLINK ${sessionName(session)}`, "ok");
        toast("UPLINK ESTABLISHED", `${sessionName(session)} // 接続完了`);
      }
      setTimeout(() => leave(g.info.demo), g.info.demo ? 700 : 180);
      return;
    }
    if (result.type === "keyboard") { // stuck Ctrl/Alt: the attempt wasn't checked, so it isn't a failure
      sfx.error();
      setStatus(up(result.error), "err");
      return;
    }
    failed++;
    updateIce();
    sfx.error();
    glitch(0.95, 380, false);
    auth.classList.remove("denied");
    void auth.offsetWidth;
    auth.classList.add("denied");
    $("cells").classList.add("denied");
    setTimeout(() => { auth.classList.remove("denied"); $("cells").classList.remove("denied"); }, 650);
    const reason = result.type === "auth_error" ? "認証失敗" : up(result.error);
    setStatus(`ACCESS DENIED // ${reason}`, "err");
    toast(failed >= 3 ? `INTRUSION ATTEMPTS: ${failed}` : `AUTH FAILURE x${failed}`,
          failed >= 3 ? "COUNTERMEASURES ARMED // 対抗措置" : "PASSPHRASE REJECTED", true);
  });

  // ---------------------------------------------------------------- power (click twice)
  const caps = await g.powerCapabilities().catch(() => ({}));
  for (const btn of document.querySelectorAll("[data-power]")) {
    const action = btn.dataset.power, label = btn.textContent;
    if (caps[action] === false) btn.hidden = true;
    let timer = null;
    btn.addEventListener("click", async () => {
      if (!btn.classList.contains("armed")) {
        btn.classList.add("armed");
        btn.textContent = `CONFIRM ${label}?`;
        sfx.tick();
        timer = setTimeout(() => { btn.classList.remove("armed"); btn.textContent = label; }, 3000);
        return;
      }
      clearTimeout(timer);
      btn.classList.remove("armed");
      btn.textContent = label;
      if (g.info.demo) {
        setStatus(`DEMO // WOULD ${label} NOW (NOTHING HAPPENS IN DEMO)`, "ok");
        return;
      }
      const goingDown = action !== "suspend";
      glitch(0.8, 300);
      setStatus(`EXECUTING // ${label}`, "ok");
      if (goingDown) leave(false);
      const r = await g.power(action).catch((err) => ({ ok: false, error: err.message }));
      if (!r.ok) {
        restore();
        sfx.error();
        setStatus(`${label} REFUSED // ${up(r.error)}`, "err");
      } else if (!goingDown) {
        setTimeout(() => selectSession(sessionIndex), 1500); // normal prompt again after waking
      }
    });
  }

  // ---------------------------------------------------------------- keyboard
  addEventListener("keydown", (e) => {
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      e.preventDefault();
      selectSession(sessionIndex + (e.key === "ArrowUp" ? -1 : 1), true);
    } else if (e.key === "Escape") {
      if (pending) { pending = null; g.cancel(); }
      pw.value = "";
      renderCells();
    }
    if (bootRunning) bootSkip = true;
  });

  // ---------------------------------------------------------------- live vitals + feed
  const HIST = 48;
  const hist = { cpu: Array(HIST).fill(0), rx: Array(HIST).fill(0), tx: Array(HIST).fill(0) };
  let lastNet = null;
  const gb = (b) => (b / 1024 ** 3).toFixed(1);
  const rate = (bps) => bps >= 1048576 ? `${(bps / 1048576).toFixed(1)} MB/S` : bps >= 1024 ? `${(bps / 1024).toFixed(0)} KB/S` : `${bps | 0} B/S`;
  const dur = (s) => {
    s = Math.floor(s);
    return `${Math.floor(s / 86400)}D ${pad(Math.floor(s / 3600) % 24)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  };
  const spark = (canvas, values, color) => {
    const dpr = devicePixelRatio || 1, w = Math.round(canvas.clientWidth * dpr), h = Math.round(canvas.clientHeight * dpr);
    if (!w || !h) return;
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    const x = canvas.getContext("2d"), max = Math.max(...values, 1e-9);
    x.clearRect(0, 0, w, h);
    x.beginPath();
    values.forEach((v, i) => {
      const px = (i / (values.length - 1)) * w, py = h - dpr - (v / max) * (h - 3 * dpr);
      i ? x.lineTo(px, py) : x.moveTo(px, py);
    });
    x.strokeStyle = color;
    x.lineWidth = 1.4 * dpr;
    x.stroke();
    x.lineTo(w, h);
    x.lineTo(0, h);
    x.closePath();
    x.fillStyle = color.replace("rgb(", "rgba(").replace(")", ", 0.14)");
    x.fill();
  };
  const meter = (id, frac, text) => {
    const el = $(id);
    el.querySelector(".bar i").style.setProperty("--v", `${Math.round(Math.min(1, Math.max(0, frac)) * 100)}%`);
    el.classList.toggle("hot", frac > 0.85);
    el.querySelector("b").textContent = text;
  };
  const poll = async () => {
    const s = await g.system().catch(() => null);
    if (!s) return;
    const now = performance.now();
    if (s.cpu != null) {
      meter("cpuMeter", s.cpu, `${Math.round(s.cpu * 100)}%`);
      hist.cpu.push(s.cpu); hist.cpu.shift();
      $("feedCpu").textContent = `${Math.round(s.cpu * 100)}%`;
    }
    if (s.mem) meter("memMeter", s.mem.used / s.mem.total, `${gb(s.mem.used)} / ${gb(s.mem.total)} GB`);
    if (s.load) $("load").textContent = s.load.map((v) => v.toFixed(2)).join(" ");
    if (s.uptime != null) {
      $("uptime").textContent = dur(s.uptime);
      $("footUptime").textContent = `UPTIME ${dur(s.uptime)}`;
    }
    if (s.net) {
      if (lastNet) {
        const dt = (now - lastNet.t) / 1000;
        const rx = Math.max(0, (s.net.rx - lastNet.rx) / dt), tx = Math.max(0, (s.net.tx - lastNet.tx) / dt);
        hist.rx.push(rx); hist.rx.shift();
        hist.tx.push(tx); hist.tx.shift();
        $("feedRx").textContent = rate(rx);
        $("feedTx").textContent = rate(tx);
      }
      lastNet = { t: now, rx: s.net.rx, tx: s.net.tx };
    }
    const p = s.power || {};
    $("pwr").textContent = p.source === "battery" ? `PWR BAT ${p.battery ?? "--"}%` : p.battery != null ? `PWR AC ${p.battery}%` : "PWR AC";
    spark($("sparkCpu"), hist.cpu, "rgb(60, 240, 255)");
    spark($("sparkRx"), hist.rx, "rgb(255, 61, 110)");
    spark($("sparkTx"), hist.tx, "rgb(255, 43, 214)");
  };
  poll();
  setInterval(poll, 1000);

  // ---------------------------------------------------------------- render loop
  let nextGlitch = performance.now() + 5000 + Math.random() * 5000;
  const frame = (now) => {
    if (opts.glitch && now > nextGlitch && !busy) {
      glitch(0.3 + Math.random() * 0.45, 110 + Math.random() * 180, false);
      nextGlitch = now + 6000 + Math.random() * 9000;
    }
    fx.frame(now, opts.parallax ? 1 : 0);
    if (opts.parallax && fx.mouse) {
      const [mx, my] = fx.mouse;
      hud.style.transform = `translate(${(-mx * 8 + Math.sin(now / 2700) * 1.5).toFixed(2)}px, ${(my * 5 + Math.cos(now / 3300) * 1.5).toFixed(2)}px)`;
    }
    requestAnimationFrame(frame);
  };

  // ---------------------------------------------------------------- boot
  const runBoot = async () => {
    const boot = $("boot");
    if (!opts.boot) { boot.classList.add("done"); fx.powerTo_(1, 450); return; }
    bootRunning = true;
    sfx.boot();
    const row = (k, v) => `> ${k} `.padEnd(34, ".") + ` ${v}`;
    const lines = lockMode ? [
      `ICE/OS SESSION LOCK // ${up(g.info.hostname)}`,
      "",
      row("OPERATOR", users[0] ? up(users[0].name) : "?"),
      row("ACTIVE SESSION", activeSession ? sessionName(activeSession) : "?"),
      row("SESSION STATE", "SUSPENDED"),
      row("COUNTERMEASURES", "ARMED"),
    ] : [
      `ICE/OS NEURAL GATE // ${up(g.info.hostname)}`,
      "",
      row("HANDSHAKE", "OK"),
      row("KERNEL", up(g.info.kernel)),
      row("OPERATOR PROFILES", `${users.length} FOUND`),
      row("UPLINK TARGETS", sessions.map(sessionName).join(", ") || "NONE"),
      row("COUNTERMEASURES", "ARMED"),
    ];
    for (const line of lines) {
      if (bootSkip) break;
      $("bootlog").textContent += line + "\n";
      await sleep(95);
    }
    if (!bootSkip) await sleep(220);
    bootRunning = false;
    boot.classList.add("done");
    fx.powerTo_(1, 650);
  };

  updateIce();
  selectSession(sessionIndex, false);
  if (lockMode) toast("SESSION LOCKED", " // 待機中", false, activeSession);
  else toast("UPLINK READY", `${sessions.length} TARGETS ONLINE // 待機中`);
  pw.focus();
  renderCells(false);
  requestAnimationFrame(frame);
  runBoot();
})();
