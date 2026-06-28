/* notchmeet — landing page behavior.
 *
 * Ported from the design prototype's DC logic class to plain DOM/JS:
 *   • the interactive notch state machine (standby → listening → thinking → streaming → presenting)
 *   • scroll-driven wake/standby (notch fused to the menu bar)
 *   • the WebGL "Living Metal" aurora bootstrap
 *   • scroll reveals, magnetic CTAs, device parallax, the menu-bar clock
 *   • the email / LINE waitlist (validation + localStorage; optional POST endpoint)
 *
 * ─────────────────────────────────────────────────────────────────────────────
 *  CONFIG — drop in real values here.
 *  • DOWNLOAD_URL: the macOS app download (e.g. a signed .dmg). "#" keeps the
 *    final CTA as a scroll-to-top placeholder.
 *  • WAITLIST_ENDPOINT: a URL that accepts POST {mode, contact}. null keeps the
 *    waitlist local-only (saved to localStorage, with the success state).
 * ─────────────────────────────────────────────────────────────────────────────
 */
(function () {
  "use strict";

  var CONFIG = {
    DOWNLOAD_URL: "#",          // TODO: real macOS download URL
    WAITLIST_ENDPOINT: null,    // TODO: real waitlist POST endpoint
    AURORA_INTENSITY: 1,        // 0.4–1.0 — master brightness of the aurora
    DEMO_AUTOPLAY: true,        // false = notch holds a single presented answer (calm mode)
  };

  // ---- product content: the interview Q&A is always Japanese (the app's output) ----
  var S = {
    ready: "待機中",
    listening: "聞き取り中…",
    thinking: "回答を生成中…",
    streaming: "回答を生成中…",
    presenting: "提示中 · そのまま読めます",
  };

  var Q = [
    { q: "自己紹介をお願いします。",
      a: "はい。〇〇大学 情報工学科の田中と申します。研究室では自然言語処理に取り組み、面接支援ツールの開発にも携わってきました。本日はよろしくお願いいたします。" },
    { q: "学生時代に最も力を入れたことは何ですか。",
      a: "学園祭の実行委員長として 50 名のチームをまとめ、来場者数を前年比 130% に伸ばしました。合意形成の難しさと、人を巻き込む力の大切さを学びました。" },
    { q: "なぜ弊社を志望するのですか。",
      a: "「技術で、誠実に課題を解く」という貴社の姿勢に強く共感しています。私の強みである粘り強さを、プロダクト開発の現場で活かしたいと考えています。" },
  ];

  // ---- module state ----
  var ns = null;          // notch render state
  var pOpen, pStatus, pRec; // last-painted values (avoid redundant DOM writes)
  var aurora = null;
  var qi = 0;
  var alive = false;
  var atTop = true;
  var tHandle, t2Handle, wakeT;  // timers used by the demo cycle
  var io = null, pll = null, magnetic = null;
  var wlMode = "email";

  var $ = function (id) { return document.getElementById(id); };
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function lucide() { if (window.lucide) window.lucide.createIcons(); }

  // ───────────────────────────── the notch ─────────────────────────────

  function notchW(open) {
    if (!open) return 248;
    var w = window.innerWidth || 1280;
    return Math.max(340, Math.min(548, w - 660));
  }

  function nset(o) { for (var k in o) ns[k] = o[k]; paint(); }

  function paint() {
    var n = $("nm-notch");
    if (!n || !ns) return;
    if (pOpen !== ns.open) {
      pOpen = ns.open;
      n.style.width = notchW(ns.open) + "px";
      n.style.borderRadius = ns.open ? "0 0 18px 18px" : "0 0 13px 13px";
      n.style.boxShadow = ns.open ? "var(--shadow-notch)" : "none";
      n.style.borderColor = ns.open ? "rgba(255,255,255,0.07)" : "transparent";
      var b = $("nm-notch-body");
      if (b) { b.style.maxHeight = ns.open ? "320px" : "0px"; b.style.opacity = ns.open ? "1" : "0"; }
      var fl = $("nm-flare-l"); if (fl) fl.style.opacity = ns.open ? "1" : "0";
      var fr = $("nm-flare-r"); if (fr) fr.style.opacity = ns.open ? "1" : "0";
    }
    if (pStatus !== ns.status || pRec !== ns.recording) {
      pStatus = ns.status; pRec = ns.recording;
      paintJewel(ns);
      var st = $("nm-status");
      if (st) st.style.color = ns.status === "presenting" ? "var(--nm-accent-notch)" : "var(--text-secondary)";
      var dot = $("nm-recdot");
      if (dot) { dot.style.background = ns.recording ? "var(--nm-recording)" : "rgba(255,255,255,0.18)"; dot.style.boxShadow = ns.recording ? "0 0 5px var(--nm-recording)" : "none"; }
      var caret = $("nm-caret");
      if (caret) caret.style.display = ns.status === "streaming" ? "inline-block" : "none";
    }
    var stx = $("nm-status"); if (stx && stx.textContent !== ns.statusText) stx.textContent = ns.statusText;
    var hr = $("nm-heard-row"); if (hr) hr.style.display = ns.heard ? "flex" : "none";
    var ht = $("nm-heard-text"); if (ht && ht.textContent !== ns.heard) ht.textContent = ns.heard;
    var at = $("nm-answer-text"); if (at && at.textContent !== ns.answer) at.textContent = ns.answer;
  }

  function paintJewel(ns) {
    var j = $("nm-jewel");
    if (!j) return;
    var acc = "var(--nm-accent-notch)";
    var h = "";
    if (ns.recording) h += '<span style="position:absolute;width:16px;height:16px;border-radius:50%;border:1.3px solid var(--nm-recording);box-shadow:0 0 5px rgba(255,69,58,0.55)"></span>';
    if (ns.status === "ready") h += '<span style="width:5px;height:5px;border-radius:50%;background:var(--text-tertiary);animation:jw-breathe 2.85s ease-in-out infinite"></span>';
    else if (ns.status === "listening") h += '<span style="width:6.5px;height:6.5px;border-radius:50%;background:var(--nm-recording);animation:jw-breathe-live 1.33s ease-in-out infinite"></span>';
    else if (ns.status === "thinking") h += '<span style="position:relative;width:12px;height:12px"><span style="position:absolute;inset:0;border-radius:50%;border:1.8px solid ' + acc + ';opacity:.16"></span><span style="position:absolute;inset:0;border-radius:50%;border:1.8px solid transparent;border-top-color:' + acc + ';animation:jw-spin 1.05s linear infinite"></span></span>';
    else if (ns.status === "streaming") h += '<span style="display:flex;align-items:center;gap:1.8px;height:12px"><span style="width:2.2px;border-radius:1px;background:' + acc + ';animation:jw-eq1 .66s ease-in-out infinite"></span><span style="width:2.2px;border-radius:1px;background:' + acc + ';animation:jw-eq2 .66s ease-in-out infinite;animation-delay:.11s"></span><span style="width:2.2px;border-radius:1px;background:' + acc + ';animation:jw-eq3 .66s ease-in-out infinite;animation-delay:.22s"></span></span>';
    else if (ns.status === "presenting") h += '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="' + acc + '" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>';
    j.innerHTML = h;
  }

  // the demo cycle
  function wait(ms) { return new Promise(function (r) { tHandle = setTimeout(r, ms); }); }

  function typeInto(field, full, per) {
    return new Promise(function (resolve) {
      var i = 0;
      (function tick() {
        if (!alive) return resolve();
        i++;
        ns[field] = full.slice(0, i);
        paint();
        if (i >= full.length) return resolve();
        t2Handle = setTimeout(tick, per);
      })();
    });
  }

  async function runCycle() {
    if (qi == null) qi = 0;
    alive = true;
    while (alive) {
      var item = Q[qi % Q.length];
      nset({ open: false, status: "ready", recording: false, heard: "", answer: "", statusText: S.ready });
      await wait(1500); if (!alive) break;
      nset({ open: true });
      await wait(540); if (!alive) break;
      nset({ status: "listening", recording: true, statusText: S.listening });
      await typeInto("heard", item.q, 40); if (!alive) break;
      await wait(680); if (!alive) break;
      nset({ status: "thinking", statusText: S.thinking });
      await wait(1150); if (!alive) break;
      nset({ status: "streaming", statusText: S.streaming });
      await typeInto("answer", item.a, 33); if (!alive) break;
      await wait(520); if (!alive) break;
      nset({ status: "presenting", recording: false, statusText: S.presenting });
      await wait(2900); if (!alive) break;
      nset({ open: false });
      await wait(720); if (!alive) break;
      qi++;
    }
  }

  function skip() {
    if (!atTop) return;
    if (CONFIG.DEMO_AUTOPLAY === false) return;
    alive = false;
    clearTimeout(tHandle); clearTimeout(t2Handle); clearTimeout(wakeT);
    qi = (qi || 0) + 1;
    wakeT = setTimeout(function () { if (atTop) runCycle(); }, 60);
  }

  function sleep() {
    alive = false;
    clearTimeout(tHandle); clearTimeout(t2Handle); clearTimeout(wakeT);
    nset({ open: false, status: "ready", recording: false, heard: "", answer: "", statusText: S.ready });
  }

  function wake() {
    clearTimeout(wakeT);
    if (CONFIG.DEMO_AUTOPLAY === false) {
      nset({ open: true, status: "presenting", recording: false, statusText: S.presenting, heard: Q[0].q, answer: Q[0].a });
      return;
    }
    alive = false;
    clearTimeout(tHandle); clearTimeout(t2Handle);
    wakeT = setTimeout(function () { if (atTop) runCycle(); }, 80);
  }

  function computeAtTop() {
    var s = $("nm-top-sentinel");
    if (s) return s.getBoundingClientRect().top > -24;
    var y = window.scrollY || window.pageYOffset || (document.documentElement && document.documentElement.scrollTop) || 0;
    return y <= 24;
  }

  function setAtTop(v) {
    if (v === atTop) return;
    atTop = v;
    if (v) wake(); else sleep();
  }

  // ───────────────────────── reveals / motion ──────────────────────────

  function initReveals() {
    var els = Array.prototype.slice.call(document.querySelectorAll("[data-reveal]"));
    if (reduceMotion) { els.forEach(function (el) { el.style.opacity = "1"; }); return; }
    els.forEach(function (el) {
      var d = parseFloat(el.getAttribute("data-reveal-delay") || "0");
      el.style.opacity = "0";
      el.style.transform = "translateY(22px)";
      el.style.transition = "opacity 0.78s cubic-bezier(0.22,0.90,0.24,1), transform 0.78s cubic-bezier(0.22,0.90,0.24,1)";
      el.style.transitionDelay = (d * 0.075) + "s";
    });
    io = new IntersectionObserver(function (ents) {
      ents.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.style.opacity = "1";
          e.target.style.transform = "translateY(0)";
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -7% 0px" });
    els.forEach(function (el) { io.observe(el); });
  }

  function initMagnetic() {
    magnetic = Array.prototype.slice.call(document.querySelectorAll("[data-magnetic]"));
    magnetic.forEach(function (el) {
      el.style.transition = "transform 0.28s cubic-bezier(0.22,0.90,0.24,1)";
      el.addEventListener("mousemove", function (e) {
        var r = el.getBoundingClientRect();
        var dx = Math.max(-6, Math.min(6, (e.clientX - (r.left + r.width / 2)) * 0.3));
        var dy = Math.max(-6, Math.min(6, (e.clientY - (r.top + r.height / 2)) * 0.3));
        el.style.transform = "translate(" + dx.toFixed(1) + "px," + dy.toFixed(1) + "px)";
      });
      el.addEventListener("mouseleave", function () { el.style.transform = "translate(0,0)"; });
    });
  }

  function updateParallax() {
    pll = pll || Array.prototype.slice.call(document.querySelectorAll("[data-parallax]"));
    var vh = window.innerHeight || 800;
    pll.forEach(function (el) {
      var r = el.getBoundingClientRect();
      var y = ((r.top + r.height / 2) - vh / 2) * -0.026;
      y = Math.max(-16, Math.min(16, y));
      el.style.transform = "translateY(" + y.toFixed(1) + "px)";
    });
  }

  // ───────────────────────────── clock ─────────────────────────────────

  function tickClock() {
    var el = $("nm-clock");
    if (!el) return;
    var d = new Date();
    el.textContent = d.getHours() + ":" + String(d.getMinutes()).padStart(2, "0");
  }

  // ──────────────────────────── waitlist ───────────────────────────────

  function initWaitlist() {
    var tabEmail = $("wl-tab-email"), tabLine = $("wl-tab-line"), thumb = $("wl-thumb");
    var input = $("wl-input"), iconEmail = $("wl-icon-email"), iconLine = $("wl-icon-line");
    var well = $("wl-well"), submit = $("wl-submit");
    if (!input || !submit || !thumb) return;

    wlMode = "email";
    function setMode(mode) {
      wlMode = mode;
      var isEmail = mode === "email";
      thumb.style.left = isEmail ? "2px" : "calc(2px + (100% - 4px)/2)";
      tabEmail.style.color = isEmail ? "var(--text-primary)" : "var(--text-secondary)";
      tabEmail.style.fontWeight = isEmail ? "600" : "500";
      tabLine.style.color = isEmail ? "var(--text-secondary)" : "var(--text-primary)";
      tabLine.style.fontWeight = isEmail ? "500" : "600";
      if (iconEmail) iconEmail.style.display = isEmail ? "inline-flex" : "none";
      if (iconLine) iconLine.style.display = isEmail ? "none" : "inline-flex";
      input.type = isEmail ? "email" : "text";
      input.placeholder = isEmail ? "you@example.com" : "LINE ID / 手机号";
      wlClearError();
    }
    tabEmail.addEventListener("click", function () { setMode("email"); });
    tabLine.addEventListener("click", function () { setMode("line"); });

    input.addEventListener("focus", function () {
      if (well) { well.style.borderColor = "var(--border-focus)"; well.style.boxShadow = "inset 0 1px 2px rgba(0,0,0,0.22), var(--shadow-focus)"; }
    });
    input.addEventListener("blur", function () {
      if (well) { well.style.borderColor = "rgba(255,255,255,0.13)"; well.style.boxShadow = "inset 0 1px 2px rgba(0,0,0,0.22)"; }
    });
    input.addEventListener("input", wlClearError);
    input.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); wlSubmit(); } });
    submit.addEventListener("click", wlSubmit);

    try {
      var saved = JSON.parse(localStorage.getItem("nm-waitlist") || "null");
      if (saved && saved.contact) wlShowSuccess(saved.contact);
    } catch (e) {}
  }

  function wlError(msg) {
    var el = $("wl-error");
    if (!el) return;
    el.textContent = msg;
    el.style.display = "flex";
    var well = $("wl-well");
    if (well) well.style.borderColor = "rgba(255,159,30,0.6)";
  }

  function wlClearError() {
    var el = $("wl-error");
    if (el) { el.style.display = "none"; el.textContent = ""; }
    var well = $("wl-well");
    if (well && document.activeElement !== $("wl-input")) well.style.borderColor = "rgba(255,255,255,0.13)";
  }

  function wlSubmit() {
    var input = $("wl-input");
    if (!input) return;
    var v = (input.value || "").trim();
    var isEmail = wlMode === "email";
    if (!v) { wlError(isEmail ? "请输入邮箱地址" : "请输入 LINE ID 或手机号"); input.focus(); return; }
    if (isEmail && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) { wlError("请输入有效的邮箱地址"); input.focus(); return; }
    var entry = { mode: wlMode, contact: v, at: Date.now() };
    try {
      var all = JSON.parse(localStorage.getItem("nm-waitlist-all") || "[]");
      all.push(entry);
      localStorage.setItem("nm-waitlist-all", JSON.stringify(all));
      localStorage.setItem("nm-waitlist", JSON.stringify(entry));
    } catch (e) {}
    // optional: forward to a real endpoint (fire-and-forget; success UX is unconditional)
    if (CONFIG.WAITLIST_ENDPOINT) {
      try {
        fetch(CONFIG.WAITLIST_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ mode: entry.mode, contact: entry.contact }),
        }).catch(function () {});
      } catch (e) {}
    }
    wlShowSuccess(v);
  }

  function wlShowSuccess(contact) {
    var form = $("wl-form"), success = $("wl-success"), ct = $("wl-success-contact");
    if (ct) ct.textContent = contact;
    if (form) form.style.display = "none";
    if (success) success.style.display = "flex";
  }

  // ──────────────────────────── bootstrap ──────────────────────────────

  function wireDownload() {
    var btn = $("nm-download-final");
    if (!btn) return;
    if (CONFIG.DOWNLOAD_URL && CONFIG.DOWNLOAD_URL !== "#") {
      btn.setAttribute("href", CONFIG.DOWNLOAD_URL);
      btn.setAttribute("download", "");
    } else {
      btn.setAttribute("href", "#top"); // placeholder: scroll to top until a real URL is set
    }
  }

  function init() {
    document.documentElement.lang = "zh";

    // aurora
    var c = $("nm-aurora");
    if (c && window.NMAurora) aurora = window.NMAurora.init(c, { intensity: CONFIG.AURORA_INTENSITY });
    window.addEventListener("mousemove", function (e) {
      if (aurora) aurora.setPointer(e.clientX / window.innerWidth, e.clientY / window.innerHeight);
    }, { passive: true });

    // keep the expanded notch sized to the viewport
    window.addEventListener("resize", function () {
      var n = $("nm-notch");
      if (n && ns && ns.open) n.style.width = notchW(true) + "px";
    }, { passive: true });

    tickClock();
    setInterval(tickClock, 15000);

    initReveals();
    initMagnetic();
    initWaitlist();
    updateParallax();
    wireDownload();

    // first paint, then icons (lucide swaps <i> → <svg>)
    ns = { open: false, status: "ready", recording: false, heard: "", answer: "", statusText: S.ready };
    paint();
    lucide();
    setTimeout(lucide, 350);
    setTimeout(lucide, 1000);

    var notch = $("nm-notch");
    if (notch) notch.addEventListener("click", skip);

    atTop = computeAtTop();
    var onScroll = function () { setAtTop(computeAtTop()); updateParallax(); };
    window.addEventListener("scroll", onScroll, { passive: true });
    document.addEventListener("scroll", onScroll, { passive: true, capture: true });
    setInterval(function () { setAtTop(computeAtTop()); updateParallax(); }, 140);

    if (atTop) wake(); else sleep();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
