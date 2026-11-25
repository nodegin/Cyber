// canvasgreet bridge: injected into the theme page before any of its own scripts.
//
//   const greeter = await window.greeterReady;     // or: addEventListener("greeter-ready", e => e.detail)
//
//   greeter.info                 { mode, hostname, demo, theme, version, preferredUser, preferredSession,
//                                  allowNetwork, options }   (options = [theme_options.<theme>] in config.toml)
//                                mode: "greeter" (login screen) or "lock" (canvaslock: one user, sessions()
//                                is just the locked session, login() unlocks it, power() only "suspend")
//   await greeter.users()        [{ name, realName, avatar (data: URL or null), last }]
//   await greeter.sessions()     [{ id, name, comment, type, desktopNames, last }]
//   await greeter.login(user, password, sessionId)
//                                -> { ok: true }  (the greeter exits shortly after and the session starts)
//                                -> { ok: false, type: "auth_error" | "error" | ..., error: "message" }
//   greeter.on("prompt",  p => ...)   extra PAM question (OTP etc.): p = { type: "secret"|"visible", message }
//                                     answer it with greeter.respond(text), or greeter.cancel()
//   greeter.on("message", m => ...)   PAM info/error text: m = { type: "info"|"error", message }
//   await greeter.power("poweroff" | "reboot" | "suspend" | "hibernate")
//                                -> { ok: true } or { ok: false, error } if systemd/polkit refused
//   await greeter.powerCapabilities()   { poweroff: true, reboot: true, suspend: true, hibernate: false }
//   await greeter.themeFiles("tracks")  [{ name, size, url }]  files in a folder of your theme
//   await greeter.system()       { uptime (s), load [1,5,15], cpu (0..1 since last call),
//                                  mem { total, used } (bytes), net { rx, tx } (bytes, add up
//                                  over time: diff two calls for a rate), power { source, battery } }
//   (greeter.info also has kernel and os, e.g. "7.2.15-zen1-1-zen", "Arch Linux")
//   greeter.log(...)             write to the greeter log (journalctl -u greetd)
(() => {
  "use strict";
  if (window.greeterReady) return;

  let resolveReady;
  window.greeterReady = new Promise((resolve) => (resolveReady = resolve));

  const pending = new Map();
  const listeners = new Map();
  let seq = 0;

  const onReply = (id, json) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    const msg = JSON.parse(json);
    if ("error" in msg) p.reject(new Error(msg.error));
    else p.resolve(msg.result);
  };

  const onEvent = (name, json) => {
    const payload = JSON.parse(json);
    for (const fn of listeners.get(name) || []) {
      try { fn(payload); } catch (e) { console.error(e); }
    }
  };

  // Two hosts, one API: Qt WebEngine (canvasgreet, the login screen) talks over a
  // QWebChannel; WebKitGTK (canvaslock, the lock screen) over a script message handler.
  function connect() {
    const webkit = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.canvasgreet;
    if (webkit) {
      window.__canvasgreet = Object.freeze({ reply: onReply, event: onEvent });
      start((id, method, args) => webkit.postMessage(JSON.stringify({ id, method, args })));
    } else if (window.qt && window.qt.webChannelTransport && window.QWebChannel) {
      new QWebChannel(window.qt.webChannelTransport, (channel) => {
        const bridge = channel.objects.bridge;
        bridge.reply.connect(onReply);
        bridge.event.connect(onEvent);
        start((id, method, args) => bridge.call(id, method, args));
      });
    } else {
      setTimeout(connect, 5);
    }
  }

  function start(send) {
    const call = (method, args) =>
      new Promise((resolve, reject) => {
        const id = String(++seq);
        pending.set(id, { resolve, reject });
        send(id, method, JSON.stringify(args || {}));
      });

    call("info").then((info) => {
      const api = Object.freeze({
        info: Object.freeze(info),
        users: () => call("users"),
        sessions: () => call("sessions"),
        login: (username, password, session) => call("login", { username, password, session }),
        respond: (text) => call("respond", { text }),
        cancel: () => call("cancel"),
        power: (action) => call("power", { action }),
        powerCapabilities: () => call("powerCapabilities"),
        themeFiles: (dir = "") => call("themeFiles", { dir }),
        system: () => call("system"),
        log: (...parts) => call("log", { message: parts.map(String).join(" ") }),
        on(name, fn) {
          if (!listeners.has(name)) listeners.set(name, new Set());
          listeners.get(name).add(fn);
          return () => listeners.get(name).delete(fn);
        },
      });
      window.greeter = api;
      resolveReady(api);
      window.dispatchEvent(new CustomEvent("greeter-ready", { detail: api }));
    });
  }

  window.addEventListener("error", (e) => console.error("uncaught:", e.message));

  // Kiosk behaviour: a login screen shouldn't act like a browser. Themes that want any of
  // this back can stop these listeners by handling the events themselves first.
  const opts = { passive: false, capture: true };
  window.addEventListener("wheel", (e) => { if (e.ctrlKey) e.preventDefault(); }, opts);  // Ctrl+scroll / pinch zoom
  window.addEventListener("dragstart", (e) => { if (e.target.closest && e.target.closest("img, a")) e.preventDefault(); }, opts);
  window.addEventListener("dragover", (e) => e.preventDefault(), opts);                     // dropped files must not open
  window.addEventListener("drop", (e) => e.preventDefault(), opts);
  connect();
})();
