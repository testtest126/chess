(function () {
  "use strict";

  var root = document.documentElement;
  var themeBtn = document.getElementById("themeBtn");
  var themeMenu = document.getElementById("themeMenu");
  var themeOpts = Array.prototype.slice.call(themeMenu.querySelectorAll(".theme-opt"));
  var eraToast = document.getElementById("eraToast");
  var canvas = document.getElementById("board");
  var ctx = canvas.getContext("2d");
  var reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- the cultural worlds ---------- */
  var SKINS = {
    "": {
      /* the default view, on MateMate's own identity: walnut #171109 ground,
         gold #E7BA5C for the gate and the reviewer, a warm verdigris packet.
         The cultural worlds below are unchanged. */
      label: "Default", glyph: "\u2726", motif: null,
      bg: "#171109", fade: "rgba(23,17,9,0.19)",
      boardTile: "rgba(242,233,214,0.016)", boardLine: "rgba(242,233,214,0.038)", filament: "rgba(231,186,92,0.07)",
      packet: "#8fd0bd", packetTrail: "rgba(143,208,189,0.5)", packetGlow: "rgba(143,208,189,0.26)",
      node: "rgba(143,208,189,0.55)", nodeCore: "rgba(176,225,210,0.9)",
      reviewer: "rgba(231,186,92,0.5)",
      gate: "rgba(231,186,92,0.85)", gateOuter: "rgba(231,186,92,0.3)", gateCore: "rgba(231,186,92,0.95)",
      pulseGold: "231,186,92", pulseFlare: "222,138,98"
    },
    arabic: {
      label: "Arabic", glyph: "\u2736", motif: "hex6",
      bg: "#0d1233", fade: "rgba(13,18,51,0.20)",
      boardTile: "rgba(212,175,55,0.02)", boardLine: "rgba(212,175,55,0.05)", filament: "rgba(212,175,55,0.08)",
      packet: "#6bc0d4", packetTrail: "rgba(79,176,196,0.5)", packetGlow: "rgba(79,176,196,0.28)",
      node: "rgba(79,176,196,0.6)", nodeCore: "rgba(150,220,232,0.9)",
      reviewer: "rgba(212,175,55,0.55)",
      gate: "rgba(212,175,55,0.9)", gateOuter: "rgba(212,175,55,0.32)", gateCore: "rgba(230,196,84,0.95)",
      pulseGold: "212,175,55", pulseFlare: "193,82,63"
    },
    japanese: {
      label: "Japanese", glyph: "\u25EF", motif: "enso",
      bg: "#f4efe4", fade: "rgba(244,239,228,0.20)",
      boardTile: "rgba(42,42,40,0.02)", boardLine: "rgba(42,42,40,0.05)", filament: "rgba(42,42,40,0.05)",
      packet: "#c94a35", packetTrail: "rgba(201,74,53,0.5)", packetGlow: "rgba(201,74,53,0.22)",
      node: "rgba(42,42,40,0.35)", nodeCore: "rgba(42,42,40,0.55)",
      reviewer: "rgba(156,131,85,0.5)",
      gate: "rgba(201,74,53,0.85)", gateOuter: "rgba(201,74,53,0.28)", gateCore: "rgba(201,74,53,0.95)",
      pulseGold: "156,131,85", pulseFlare: "201,74,53"
    },
    indian: {
      label: "Indian", glyph: "\u2740", motif: "lotus",
      bg: "#2a0f14", fade: "rgba(42,15,20,0.20)",
      boardTile: "rgba(232,160,32,0.02)", boardLine: "rgba(232,160,32,0.05)", filament: "rgba(232,160,32,0.09)",
      packet: "#3ecad0", packetTrail: "rgba(43,179,173,0.5)", packetGlow: "rgba(43,179,173,0.28)",
      node: "rgba(43,179,173,0.6)", nodeCore: "rgba(140,230,220,0.9)",
      reviewer: "rgba(232,160,32,0.55)",
      gate: "rgba(232,160,32,0.9)", gateOuter: "rgba(232,160,32,0.32)", gateCore: "rgba(240,190,80,0.95)",
      pulseGold: "232,160,32", pulseFlare: "200,29,58"
    },
    codex: {
      label: "Codex", glyph: "\u2766", motif: null,
      bg: "#ece0c0", fade: "rgba(236,224,192,0.20)",
      boardTile: "rgba(43,32,19,0.02)", boardLine: "rgba(43,32,19,0.05)", filament: "rgba(175,138,46,0.08)",
      packet: "#a3241c", packetTrail: "rgba(163,36,28,0.5)", packetGlow: "rgba(163,36,28,0.22)",
      node: "rgba(63,122,110,0.5)", nodeCore: "rgba(63,122,110,0.75)",
      reviewer: "rgba(175,138,46,0.55)",
      gate: "rgba(163,36,28,0.85)", gateOuter: "rgba(163,36,28,0.28)", gateCore: "rgba(163,36,28,0.95)",
      pulseGold: "175,138,46", pulseFlare: "163,36,28"
    },
    andalus: {
      label: "El-Andalus", glyph: "\u2734", motif: "star8",
      bg: "#062a28", fade: "rgba(6,42,40,0.20)",
      boardTile: "rgba(201,150,60,0.02)", boardLine: "rgba(201,150,60,0.06)", filament: "rgba(201,150,60,0.09)",
      packet: "#4fd4c2", packetTrail: "rgba(47,179,166,0.5)", packetGlow: "rgba(47,179,166,0.28)",
      node: "rgba(47,179,166,0.6)", nodeCore: "rgba(140,230,216,0.9)",
      reviewer: "rgba(201,150,60,0.55)",
      gate: "rgba(201,150,60,0.9)", gateOuter: "rgba(201,150,60,0.32)", gateCore: "rgba(224,186,100,0.95)",
      pulseGold: "201,150,60", pulseFlare: "193,99,63"
    },
    terminal: {
      label: "Terminal", glyph: "\u276F", motif: "plus",
      bg: "#080b0a", fade: "rgba(8,11,10,0.22)",
      boardTile: "rgba(72,208,106,0.015)", boardLine: "rgba(72,208,106,0.05)", filament: "rgba(72,208,106,0.08)",
      packet: "#6ee08a", packetTrail: "rgba(72,208,106,0.5)", packetGlow: "rgba(72,208,106,0.26)",
      node: "rgba(72,208,106,0.6)", nodeCore: "rgba(130,240,160,0.9)",
      reviewer: "rgba(72,208,106,0.5)",
      gate: "rgba(72,208,106,0.9)", gateOuter: "rgba(72,208,106,0.3)", gateCore: "rgba(140,240,170,0.95)",
      pulseGold: "72,208,106", pulseFlare: "224,87,74"
    }
  };
  // the dial starts at the untouched default -- everything else is opt-in
  var order = ["", "arabic", "japanese", "indian", "codex", "andalus", "terminal"];
  var skinIdx = 0;
  var S = SKINS[""];

  var W = 0, H = 0, DPR = 1, board = null;

  var workers = [
    { x: 0.13, y: 0.24 }, { x: 0.08, y: 0.55 }, { x: 0.19, y: 0.82 },
    { x: 0.28, y: 0.40 }, { x: 0.22, y: 0.66 }
  ];
  var gate = { x: 0.72, y: 0.5 };
  var reviewer = { x: 0.85, y: 0.34 };

  var packets = [];
  var pulses = [];
  var arrivals = 0;

  function P(nx, ny) { return { x: nx * W, y: ny * H }; }

  // ---- the per-theme board motifs, each an echo of that world's ornament ----
  function miniStar8(b, x, y, r) {
    b.save(); b.translate(x, y);
    b.strokeRect(-r, -r, 2 * r, 2 * r);
    b.rotate(Math.PI / 4); b.strokeRect(-r, -r, 2 * r, 2 * r);
    b.restore();
  }
  function polyStroke(b, x, y, n, r, rot) {
    b.beginPath();
    for (var k = 0; k < n; k++) {
      var a = rot + k * 2 * Math.PI / n;
      var px = x + r * Math.cos(a), py = y + r * Math.sin(a);
      if (k === 0) b.moveTo(px, py); else b.lineTo(px, py);
    }
    b.closePath(); b.stroke();
  }
  function miniHex6(b, x, y, r) { polyStroke(b, x, y, 6, r, -Math.PI / 2); }
  function miniLotus(b, x, y, r) {
    b.beginPath(); b.arc(x, y, r * 0.55, 0, 6.2832); b.stroke();
    b.save(); b.translate(x, y); b.rotate(Math.PI / 4);
    b.strokeRect(-r, -r, 2 * r, 2 * r); b.restore();
  }
  function miniPlus(b, x, y, r) {
    b.beginPath();
    b.moveTo(x - r, y); b.lineTo(x + r, y);
    b.moveTo(x, y - r); b.lineTo(x, y + r);
    b.stroke();
  }
  function miniEnso(b, x, y, r) {
    b.beginPath(); b.arc(x, y, r * 0.7, -Math.PI * 0.42, Math.PI * 1.2); b.stroke();
  }
  function drawMotif(b, x, y, r) {
    if (S.motif === "star8") miniStar8(b, x, y, r);
    else if (S.motif === "hex6") miniHex6(b, x, y, r);
    else if (S.motif === "lotus") miniLotus(b, x, y, r);
    else if (S.motif === "plus") miniPlus(b, x, y, r * 1.2);
    else if (S.motif === "enso") miniEnso(b, x, y, r);
  }

  function buildBoard() {
    board = document.createElement("canvas");
    board.width = canvas.width; board.height = canvas.height;
    var b = board.getContext("2d");
    b.scale(DPR, DPR);
    var cols = 8, rows = 8;
    var cw = W / cols, ch = H / rows;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        if ((r + c) % 2 === 0) { b.fillStyle = S.boardTile; b.fillRect(c * cw, r * ch, cw, ch); }
      }
    }
    b.strokeStyle = S.boardLine;
    b.lineWidth = 1;
    for (var i = 1; i < cols; i++) { b.beginPath(); b.moveTo(i * cw, 0); b.lineTo(i * cw, H); b.stroke(); }
    for (var j = 1; j < rows; j++) { b.beginPath(); b.moveTo(0, j * ch); b.lineTo(W, j * ch); b.stroke(); }
    if (S.motif) {
      var rr = Math.min(cw, ch) * 0.17;
      b.strokeStyle = S.filament;
      b.lineWidth = 1;
      for (var gi = 1; gi < cols; gi++) {
        for (var gj = 1; gj < rows; gj++) { drawMotif(b, gi * cw, gj * ch, rr); }
      }
    }
    var g = P(gate.x, gate.y);
    b.strokeStyle = S.filament;
    b.lineWidth = 1;
    for (var k = 0; k < workers.length; k++) {
      var w = P(workers[k].x, workers[k].y);
      b.beginPath(); b.moveTo(w.x, w.y);
      b.quadraticCurveTo((w.x + g.x) / 2, (w.y + g.y) / 2 - H * 0.08, g.x, g.y);
      b.stroke();
    }
  }

  function resize() {
    W = canvas.clientWidth || (canvas.parentElement && canvas.parentElement.clientWidth) || window.innerWidth;
    H = canvas.clientHeight || (canvas.parentElement && canvas.parentElement.clientHeight) || Math.round(window.innerHeight * 0.9);
    if (!W) W = window.innerWidth;
    if (!H) H = Math.round(window.innerHeight * 0.9);
    DPR = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.max(1, Math.round(W * DPR));
    canvas.height = Math.max(1, Math.round(H * DPR));
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    buildBoard();
  }

  function spawnPacket() {
    var from = workers[(Math.random() * workers.length) | 0];
    var toGate = Math.random() < 0.78;
    var a = P(from.x, from.y), t;
    if (toGate) { t = P(gate.x, gate.y); }
    else { var other = workers[(Math.random() * workers.length) | 0]; t = P(other.x, other.y); }
    var cx = (a.x + t.x) / 2 + (Math.random() - 0.5) * W * 0.16;
    var cy = (a.y + t.y) / 2 - H * (0.05 + Math.random() * 0.14);
    packets.push({ ax: a.x, ay: a.y, cx: cx, cy: cy, tx: t.x, ty: t.y, p: 0, speed: 0.0035 + Math.random() * 0.004, toGate: toGate, trail: [] });
  }

  function bez(a, c, b, p) { var m = 1 - p; return m * m * a + 2 * m * p * c + p * p * b; }

  function seedPackets() {
    for (var i = 0; i < 6; i++) {
      spawnPacket();
      var pk = packets[packets.length - 1];
      pk.p = 0.14 + Math.random() * 0.68;
      for (var s = 0; s < 10; s++) {
        var pp = Math.max(0, pk.p - (10 - s) * 0.012);
        pk.trail.push(bez(pk.ax, pk.cx, pk.tx, pp), bez(pk.ay, pk.cy, pk.ty, pp));
      }
    }
  }

  function step() {
    ctx.fillStyle = S.fade;
    ctx.fillRect(0, 0, W, H);
    ctx.drawImage(board, 0, 0, W, H);

    ctx.globalCompositeOperation = "lighter";

    for (var i = packets.length - 1; i >= 0; i--) {
      var pk = packets[i];
      pk.p += pk.speed;
      var x = bez(pk.ax, pk.cx, pk.tx, pk.p);
      var y = bez(pk.ay, pk.cy, pk.ty, pk.p);
      pk.trail.push(x, y);
      if (pk.trail.length > 16) pk.trail.splice(0, 2);

      ctx.strokeStyle = S.packetTrail;
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      for (var s = 0; s < pk.trail.length; s += 2) {
        if (s === 0) ctx.moveTo(pk.trail[s], pk.trail[s + 1]);
        else ctx.lineTo(pk.trail[s], pk.trail[s + 1]);
      }
      ctx.stroke();

      ctx.fillStyle = S.packet;
      ctx.beginPath(); ctx.arc(x, y, 2.1, 0, 6.2832); ctx.fill();
      ctx.fillStyle = S.packetGlow;
      ctx.beginPath(); ctx.arc(x, y, 5.5, 0, 6.2832); ctx.fill();

      if (pk.p >= 1) {
        if (pk.toGate) {
          arrivals++;
          var g = P(gate.x, gate.y);
          if (arrivals % 8 === 0) pulses.push({ x: g.x, y: g.y, r: 4, max: 46, c: "flare" });
          else pulses.push({ x: g.x, y: g.y, r: 3, max: 30, c: "gold" });
        }
        packets.splice(i, 1);
      }
    }

    for (var q = pulses.length - 1; q >= 0; q--) {
      var pu = pulses[q];
      pu.r += (pu.max - pu.r) * 0.06 + 0.4;
      var a = 1 - pu.r / pu.max;
      if (pu.c === "gold") ctx.strokeStyle = "rgba(" + S.pulseGold + "," + (a * 0.7).toFixed(3) + ")";
      else ctx.strokeStyle = "rgba(" + S.pulseFlare + "," + (a * 0.8).toFixed(3) + ")";
      ctx.lineWidth = 1.6;
      ctx.beginPath(); ctx.arc(pu.x, pu.y, pu.r, 0, 6.2832); ctx.stroke();
      if (a <= 0.04) pulses.splice(q, 1);
    }

    ctx.globalCompositeOperation = "source-over";

    for (var n = 0; n < workers.length; n++) {
      var wp = P(workers[n].x, workers[n].y);
      ctx.strokeStyle = S.node;
      ctx.lineWidth = 1.2;
      ctx.beginPath(); ctx.arc(wp.x, wp.y, 5, 0, 6.2832); ctx.stroke();
      ctx.fillStyle = S.nodeCore;
      ctx.beginPath(); ctx.arc(wp.x, wp.y, 1.6, 0, 6.2832); ctx.fill();
    }
    var rv = P(reviewer.x, reviewer.y);
    ctx.strokeStyle = S.reviewer;
    ctx.lineWidth = 1.2;
    ctx.beginPath(); ctx.arc(rv.x, rv.y, 6, 0, 6.2832); ctx.stroke();

    var gp = P(gate.x, gate.y);
    ctx.strokeStyle = S.gate;
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(gp.x, gp.y, 11, 0, 6.2832); ctx.stroke();
    ctx.strokeStyle = S.gateOuter;
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.arc(gp.x, gp.y, 17, 0, 6.2832); ctx.stroke();
    ctx.fillStyle = S.gateCore;
    ctx.beginPath(); ctx.arc(gp.x, gp.y, 3, 0, 6.2832); ctx.fill();
  }

  var emitAcc = 0, last = 0, running = false, rafId = 0;
  function loop(ts) {
    if (!running) return;
    var dt = ts - last; last = ts;
    emitAcc += dt;
    if (emitAcc > 520 && packets.length < 14) { spawnPacket(); emitAcc = 0; }
    step();
    rafId = requestAnimationFrame(loop);
  }

  function staticFrame() {
    ctx.fillStyle = S.bg; ctx.fillRect(0, 0, W, H);
    ctx.drawImage(board, 0, 0, W, H);
    ctx.globalCompositeOperation = "lighter";
    for (var k = 0; k < workers.length; k++) {
      var a = P(workers[k].x, workers[k].y), t = P(gate.x, gate.y);
      var cx = (a.x + t.x) / 2, cy = (a.y + t.y) / 2 - H * 0.09;
      var p = 0.35 + k * 0.12;
      var x = bez(a.x, cx, t.x, p), y = bez(a.y, cy, t.y, p);
      ctx.strokeStyle = S.packetTrail; ctx.lineWidth = 1.3;
      ctx.beginPath(); ctx.moveTo(a.x, a.y);
      ctx.quadraticCurveTo(cx, cy, x, y); ctx.stroke();
      ctx.fillStyle = S.packet; ctx.beginPath(); ctx.arc(x, y, 2.2, 0, 6.2832); ctx.fill();
    }
    ctx.globalCompositeOperation = "source-over";
    for (var n = 0; n < workers.length; n++) {
      var wp = P(workers[n].x, workers[n].y);
      ctx.strokeStyle = S.node; ctx.lineWidth = 1.2;
      ctx.beginPath(); ctx.arc(wp.x, wp.y, 5, 0, 6.2832); ctx.stroke();
    }
    var gp = P(gate.x, gate.y);
    ctx.strokeStyle = S.gate; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(gp.x, gp.y, 11, 0, 6.2832); ctx.stroke();
    ctx.fillStyle = S.gateCore;
    ctx.beginPath(); ctx.arc(gp.x, gp.y, 3, 0, 6.2832); ctx.fill();
  }

  function start() { if (running || reduce) return; running = true; last = performance.now(); rafId = requestAnimationFrame(loop); }
  function stop() { running = false; if (rafId) cancelAnimationFrame(rafId); }

  function paintFirst() {
    resize();
    packets.length = 0; pulses.length = 0;
    seedPackets();
    if (reduce) staticFrame(); else step();
  }

  /* ---------- theme switcher : menu-button + menuitemradio, 7 options ---------- */
  var BLURB = {
    "":       "Default \u00b7 the untouched view",
    arabic:   "Arabic \u00b7 kufic geometry, indigo + gold",
    japanese: "Japanese \u00b7 sumi-e minimalism, washi + vermillion",
    indian:   "Indian \u00b7 ornamental jewel tones",
    codex:    "Codex \u00b7 illuminated manuscript",
    andalus:  "El-Andalus \u00b7 azulejo + horseshoe geometry",
    terminal: "Terminal \u00b7 CRT phosphor"
  };
  var toastTimer;
  function showEra(id) {
    if (!eraToast) return;
    eraToast.textContent = BLURB[id];
    eraToast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { eraToast.classList.remove("show"); }, 2600);
  }
  function closeMenu(refocusBtn) {
    themeMenu.hidden = true;
    themeBtn.setAttribute("aria-expanded", "false");
    if (refocusBtn) themeBtn.focus();
  }
  function openMenu() {
    themeMenu.hidden = false;
    themeBtn.setAttribute("aria-expanded", "true");
    (themeOpts[skinIdx] || themeOpts[0]).focus();
  }
  function applySkin(id, announce) {
    S = SKINS[id];
    skinIdx = order.indexOf(id);
    if (id === "") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", id);
    themeBtn.textContent = S.glyph + "  " + S.label;
    themeOpts.forEach(function (opt) {
      opt.setAttribute("aria-checked", opt.getAttribute("data-theme") === id ? "true" : "false");
    });
    try { localStorage.setItem("mm-theme", id); } catch (e) {}
    if (announce) showEra(id);
    paintFirst();
    if (!reduce) start();
  }

  themeBtn.addEventListener("click", function () {
    if (themeMenu.hidden) openMenu(); else closeMenu(false);
  });
  themeBtn.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); openMenu(); }
    else if (e.key === "Escape") { closeMenu(false); }
  });
  themeOpts.forEach(function (opt, i) {
    opt.addEventListener("click", function () {
      applySkin(opt.getAttribute("data-theme"), true);
      closeMenu(true);
    });
    opt.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); themeOpts[(i + 1) % themeOpts.length].focus(); }
      else if (e.key === "ArrowUp") { e.preventDefault(); themeOpts[(i - 1 + themeOpts.length) % themeOpts.length].focus(); }
      else if (e.key === "Home") { e.preventDefault(); themeOpts[0].focus(); }
      else if (e.key === "End") { e.preventDefault(); themeOpts[themeOpts.length - 1].focus(); }
      else if (e.key === "Escape") { e.preventDefault(); closeMenu(true); }
    });
  });
  themeMenu.addEventListener("focusout", function (e) {
    var next = e.relatedTarget;
    if (!next || (!themeMenu.contains(next) && next !== themeBtn)) closeMenu(false);
  });
  document.addEventListener("click", function (e) {
    if (!themeMenu.hidden && !themeMenu.contains(e.target) && e.target !== themeBtn) closeMenu(false);
  });

  // A #theme=<id> in the URL wins (shareable links, and how the launch screenshots were taken);
  // otherwise restore the visitor's last choice; otherwise open on the untouched default.
  function hashTheme() {
    var m = /(?:^|[#&])theme=([a-z]*)/.exec(location.hash);
    return m ? m[1] : null;
  }
  var fromHash = hashTheme();
  var savedTheme = null;
  if (fromHash === null) { try { savedTheme = localStorage.getItem("mm-theme"); } catch (e) {} }
  var initialTheme = fromHash !== null && SKINS.hasOwnProperty(fromHash) ? fromHash : savedTheme;
  if (initialTheme !== null && SKINS.hasOwnProperty(initialTheme)) {
    applySkin(initialTheme, false);
  } else {
    paintFirst();
    if (!reduce) start();
    themeBtn.textContent = S.glyph + "  " + S.label;
  }

  window.addEventListener("load", function () {
    paintFirst();
    if (!reduce) start();
    // enable the palette crossfade only after the first paint, so load doesn't flash
    setTimeout(function () { root.classList.add("skin-anim"); }, 60);
  });

  /* ---------- reading progress ----------
     These chapters run long, so the scroll position is worth showing. The bar is
     created here rather than in the markup so every page gets it without a
     twelve-file edit; it is inert under prefers-reduced-motion (hidden in CSS). */
  if (!reduce) {
    var bar = document.createElement("div");
    bar.className = "read-progress";
    bar.setAttribute("aria-hidden", "true");
    document.body.appendChild(bar);
    var ticking = false;
    function drawProgress() {
      var max = document.documentElement.scrollHeight - window.innerHeight;
      var frac = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
      bar.style.transform = "scaleX(" + frac + ")";
      ticking = false;
    }
    window.addEventListener("scroll", function () {
      if (!ticking) { ticking = true; requestAnimationFrame(drawProgress); }
    }, { passive: true });
    window.addEventListener("resize", drawProgress);
    drawProgress();
  }

  var rt;
  window.addEventListener("resize", function () { clearTimeout(rt); rt = setTimeout(paintFirst, 160); });

  if ("ResizeObserver" in window) {
    var ro = new ResizeObserver(function () {
      var w = canvas.clientWidth, h = canvas.clientHeight;
      if (w && h && (Math.abs(w - W) > 1 || Math.abs(h - H) > 1)) { paintFirst(); if (!reduce) start(); }
    });
    ro.observe(canvas);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) start(); else stop(); });
    }, { threshold: 0.02 }).observe(canvas);
  }
})();
