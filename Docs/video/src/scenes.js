/* Lantern intro — deterministic scene timeline. window.seek(t) renders the frame at time t (seconds). */
(function () {
  const TL = window.TL;
  const GIF = /[?&]gif=1/.test(location.search);
  const W = 1920, H = 1080;
  const $ = (s) => document.querySelector(s);
  const el = (tag, attrs = {}, parent) => {
    const svgTags = ['svg', 'g', 'rect', 'path', 'line', 'circle', 'text', 'tspan', 'defs', 'marker', 'polygon', 'linearGradient', 'stop'];
    const n = svgTags.includes(tag) ? document.createElementNS('http://www.w3.org/2000/svg', tag) : document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'text') n.textContent = v; else if (k === 'html') n.innerHTML = v; else if (k === 'style' && typeof v === 'object') Object.assign(n.style, v); else n.setAttribute(k, v);
    }
    if (parent) parent.appendChild(n);
    return n;
  };
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const ramp = (t, a, b) => clamp((t - a) / (b - a));
  const sm = (x) => x * x * (3 - 2 * x);
  const lerp = (a, b, k) => a + (b - a) * k;
  function rng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

  const scene = Object.fromEntries(TL.scenes.map((s) => [s.id, s]));
  const line = Object.fromEntries(TL.lines.map((l) => [l.id, l]));
  const cue = (id, name) => line[id].cues[name];
  const tl = gsap.timeline({ paused: true });
  const per = [];               // per-frame callbacks f(t)
  // music grid (72 BPM, 8th notes) — sparkle events snap to it so sound and light land together
  const EIGHTH = 60 / 72 / 2;
  const q = (t) => Math.round(t / EIGHTH) * EIGHTH;
  const EVENTS = [];
  const ev = (t, kind, i = 0) => { const tq = q(t); EVENTS.push({ t: +tq.toFixed(4), kind, i }); return tq; };
  window.EVENTS = EVENTS;

  // ---------------------------------------------------------------- sky
  const sky = $('#sky'), sctx = sky.getContext('2d');
  const base = document.createElement('canvas'); base.width = W; base.height = H;
  {
    const c = base.getContext('2d');
    const g = c.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, '#050e19'); g.addColorStop(0.45, '#081a2b'); g.addColorStop(1, '#0e2c45');
    c.fillStyle = g; c.fillRect(0, 0, W, H);
  }
  const R = rng(7);
  const stars = Array.from({ length: 230 }, () => ({ x: R() * W, y: R() * H * 0.98, r: 0.5 + R() * R() * 1.5, a: 0.18 + R() * 0.6, f: 0.05 + R() * 0.18, p: R() * 6.28 }));
  const G = { x: 960, y: 420, r: 760, a: 0 };
  function drawSky(t) {
    sctx.drawImage(base, 0, 0);
    const a = GIF ? G.a : G.a * (1 + 0.035 * Math.sin(t * 1.05) + 0.02 * Math.sin(t * 2.3 + 1.3));
    if (a > 0.002) {
      const g = sctx.createRadialGradient(G.x, G.y, 0, G.x, G.y, G.r);
      g.addColorStop(0, `rgba(255,176,82,${0.30 * a})`); g.addColorStop(0.35, `rgba(214,140,70,${0.12 * a})`); g.addColorStop(1, 'rgba(160,110,60,0)');
      sctx.fillStyle = g; sctx.fillRect(0, 0, W, H);
    }
    for (const s of stars) {
      const tw = GIF ? 1 : 0.72 + 0.28 * Math.sin(t * s.f * 6.28 + s.p);
      sctx.globalAlpha = s.a * tw; sctx.fillStyle = '#dfe8ff';
      sctx.beginPath(); sctx.arc(s.x, s.y, s.r, 0, 6.283); sctx.fill();
    }
    sctx.globalAlpha = 1;
  }
  const glowTo = (at, x, y, r, a, d = 1.4) => tl.to(G, { x, y, r, a, duration: d, ease: 'sine.inOut' }, at);

  // ---------------------------------------------------------------- scene fades, chapter, brand, subtitles
  const chapScenes = TL.scenes.filter((s) => s.chapter);
  TL.scenes.forEach((s, i) => {
    const n = document.getElementById('s-' + s.id);
    gsap.set(n, { autoAlpha: 0 });
    // dip through the night sky instead of cross-dissolving two dense layouts
    if (i === 0) tl.set(n, { autoAlpha: 1 }, 0);
    else tl.fromTo(n, { autoAlpha: 0 }, { autoAlpha: 1, duration: 0.6, ease: 'power1.out', immediateRender: false }, s.start + 0.25);
    if (i < TL.scenes.length - 1) tl.to(n, { autoAlpha: 0, duration: 0.42, ease: 'power1.in' }, TL.scenes[i + 1].start - 0.15);
  });
  const chap = $('#chapter'), chNum = $('#chNum'), chName = $('#chName'), brand = $('#brand');
  per.push((t) => {
    let cur = null;
    for (const s of TL.scenes) if (t >= s.start - 0.4) cur = s;
    let op = 0;
    if (cur && cur.chapter) {
      const i = chapScenes.indexOf(cur);
      chNum.textContent = String(i + 1).padStart(2, '0'); chName.textContent = cur.chapter;
      op = sm(ramp(t, cur.start + 0.25, cur.start + 0.85)) * (1 - sm(ramp(t, cur.end - 0.45, cur.end + 0.05)));
    }
    chap.style.opacity = op;
    const b0 = scene.private.start, b1 = scene.outro.start;
    brand.style.opacity = 0.85 * sm(ramp(t, b0 + 0.3, b0 + 1.2)) * (1 - sm(ramp(t, b1 - 0.2, b1 + 0.6)));
  });
  const gifcap = $('#gifcap');
  window.gifCap = (text, a) => { gifcap.textContent = text || ''; gifcap.style.opacity = text ? a : 0; };
  const subsBox = $('#subs');
  const subEls = TL.lines.map((l) => el('div', { class: 'sub', text: l.cap }, subsBox));
  per.push((t) => {
    TL.lines.forEach((l, i) => {
      const o = sm(ramp(t, l.start - 0.18, l.start + 0.08)) * (1 - sm(ramp(t, l.end + 0.05, l.end + 0.3)));
      subEls[i].style.opacity = GIF ? 0 : o;
    });
  });

  // helpers for screenshot windows
  function camSet(win, c) {
    const w = win.clientWidth, h = win.clientHeight;
    return { x: w / 2 - c.s * c.cx, y: h / 2 - c.s * c.cy, scale: c.s };
  }
  function cam(win, at, c, d = 1.2, ease = 'power2.inOut') {
    const cm = win.querySelector('.cam');
    if (at === null) gsap.set(cm, { ...camSet(win, c), transformOrigin: '0 0' });
    else tl.to(cm, { ...camSet(win, c), duration: d, ease }, at);
  }
  function hl(win, x, y, w, h, cls = '') {
    return el('div', { class: 'hl ' + cls, style: { left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px' } }, win.querySelector('.cam'));
  }
  const show = (n, at, d = 0.5, from = {}) => tl.fromTo(n, { autoAlpha: 0, ...from }, { autoAlpha: 1, x: 0, y: 0, scale: 1, duration: d, ease: 'power2.out', immediateRender: false }, at);
  const hide = (n, at, d = 0.4) => tl.to(n, { autoAlpha: 0, duration: d, ease: 'power1.in' }, at);
  const pulse = (n, at) => tl.fromTo(n, { scale: 1 }, { scale: 1.08, duration: 0.18, yoyo: true, repeat: 1, ease: 'sine.inOut', immediateRender: false }, at);

  // ================================================================= S1 OPEN
  {
    const fb = $('#fadeBlack');
    gsap.set(fb, { opacity: 1 });
    tl.to(fb, { opacity: 0, duration: 1.4, ease: 'sine.out' }, 0.0);
    const mid = $('#lgMid'), front = $('#lgFront'), glow = $('#lgGlow');
    gsap.set(mid, { opacity: 0, y: 26, scale: 0.97, filter: 'brightness(0.22) saturate(0.6)' });
    gsap.set(front, { opacity: 0, scale: 0.94 });
    gsap.set(glow, { opacity: 0, scale: 0.7 });
    tl.to(mid, { opacity: 1, y: 0, scale: 1, duration: 2.0, ease: 'power2.out' }, 0.4);
    tl.to(mid, { filter: 'brightness(1) saturate(1)', duration: 1.3, ease: 'power2.inOut' }, 1.3);
    tl.to(glow, { opacity: 1, scale: 1, duration: 1.8, ease: 'power2.out' }, 1.5);
    tl.to(front, { opacity: 1, scale: 1, duration: 1.6, ease: 'power2.out' }, 2.3);
    glowTo(1.2, 960, 420, 820, 1.0, 2.2);
    const title = $('#title'), tag = $('#tagline');
    gsap.set(title, { opacity: 0, y: 24, letterSpacing: '0.07em' });
    tl.to(title, { opacity: 1, y: 0, letterSpacing: '0.005em', duration: 1.4, ease: 'power3.out' }, ev(cue('L01', 'lantern') - 0.1, 'title'));
    gsap.set(tag, { opacity: 0, y: 14 });
    tl.to(tag, { opacity: 1, y: 0, duration: 1.0, ease: 'power2.out' }, cue('L01', 'lit'));
    // gentle breathing of the lantern light
    per.push((t) => { glow.style.transform = `scale(${GIF ? 1 : 1 + 0.02 * Math.sin(t * 1.3)})`; });
  }

  // ================================================================= S2 PRIVATE
  {
    const s = scene.private;
    glowTo(s.start, 650, 530, 950, 0.55);
    const dev = $('#device');
    show(dev, s.start + 0.1, 0.9, { scale: 0.96 });
    const files = [
      ['documents.json', '문서 목록'], ['chunks.json', '청크 · 벡터 · 키워드'], ['graph-entities.json', '지식 그래프 개념'],
      ['graph-relations.json', '지식 그래프 관계'], ['conversations.json', '대화 기록'], ['harness-policy.json', '하네스 정책'], ['mcp-servers.json', 'MCP 서버 설정'],
    ];
    const icon = '<svg class="ic" viewBox="0 0 34 40"><path d="M4 2h18l9 9v27H4z" fill="rgba(255,200,130,0.10)" stroke="#e9c27c" stroke-width="2"/><path d="M22 2v9h9" fill="none" stroke="#e9c27c" stroke-width="2"/><path d="M10 22h14M10 28h10" stroke="#e9c27c" stroke-width="2" stroke-linecap="round"/></svg>';
    files.forEach(([fn, fd], i) => {
      const r = el('div', { class: 'frow', style: { top: 110 + i * 82 + 'px' }, html: `${icon}<div class="fn">${fn}</div><div class="fd">${fd}</div>` }, dev);
      show(r, cue('L02', 'apple') + 0.5 + i * 0.32, 0.5, { x: -18 });
    });
    const js = $('#jsonCard');
    js.innerHTML = '<span class="c">// chunks.json (KnowledgeChunk)</span>\n{\n  <span class="p">"documentTitle"</span>: <span class="s">"Lantern(랜턴) 사용 안내"</span>,\n  <span class="p">"text"</span>: <span class="s">"Lantern의 검색은 하이브리드…"</span>,\n  <span class="p">"vector"</span>: [ <span class="c">/* 512차원 */</span> ],\n  <span class="p">"keywords"</span>: [ <span class="c">…</span> ]\n}';
    show(js, cue('L02', 'json') - 0.2, 0.7, { y: 20 });
    const nc = $('#netCard');
    show(nc, cue('L03', 'network') - 0.3, 0.7, { y: 20 });
    pulse(nc.querySelector('.zero'), cue('L03', 'zero'));
    // motes that try to leave the device and are turned back at its edge
    const box = { l: 150, t: 170, r: 1150, b: 890 };
    const mr = rng(21);
    const motes = Array.from({ length: 14 }, (_, i) => {
      const n = el('div', { class: 'mote' }, $('#s-private'));
      const ang = mr() * 6.283;
      const x0 = 420 + mr() * 460, y0 = 330 + mr() * 380;
      return { n, x0, y0, vx: Math.cos(ang) * (150 + mr() * 70), vy: Math.sin(ang) * (150 + mr() * 70), t0: cue('L03', 'docs') - 0.4 + i * 0.16 };
    });
    const ripples = motes.map(() => el('div', { style: { position: 'absolute', width: '10px', height: '10px', margin: '-5px 0 0 -5px', borderRadius: '50%', border: '2px solid rgba(255,200,130,0.9)', opacity: 0 } }, $('#s-private')));
    per.push((t) => {
      motes.forEach((m, i) => {
        const dt = t - m.t0;
        const rp = ripples[i];
        if (dt < 0 || dt > 4.2) { m.n.style.opacity = 0; rp.style.opacity = 0; return; }
        const tx = m.vx > 0 ? (box.r - 14 - m.x0) / m.vx : (box.l + 14 - m.x0) / m.vx;
        const ty = m.vy > 0 ? (box.b - 14 - m.y0) / m.vy : (box.t + 14 - m.y0) / m.vy;
        const th = Math.min(tx, ty);
        let x, y;
        if (dt < th) { x = m.x0 + m.vx * dt; y = m.y0 + m.vy * dt; }
        else {
          const hx = m.x0 + m.vx * th, hy = m.y0 + m.vy * th, k = (dt - th) * 0.55;
          x = hx - (tx <= ty ? m.vx : -m.vx) * k; y = hy - (tx <= ty ? -m.vy : m.vy) * k;
          const rk = clamp((dt - th) / 0.7);
          rp.style.left = hx + 'px'; rp.style.top = hy + 'px';
          rp.style.transform = `scale(${1 + rk * 5})`; rp.style.opacity = (1 - rk) * 0.8;
        }
        if (dt < th) rp.style.opacity = 0;
        m.n.style.left = x + 'px'; m.n.style.top = y + 'px';
        m.n.style.opacity = sm(ramp(dt, 0, 0.3)) * (1 - sm(ramp(dt, 3.2, 4.2)));
      });
    });
  }

  // ================================================================= S3 STACK
  {
    const s = scene.stack;
    glowTo(s.start, 960, 470, 820, 0.85);
    const svg = $('#stackSvg');
    const C = { x: 960, y: 455 };
    const nodes = [
      { k: 'rag', x: 470, y: 300, t: 'RAG · 하이브리드 검색', d: '문장 임베딩 + 키워드', up: true },
      { k: 'kg', x: 960, y: 170, t: '지식 그래프', d: '주어-술어-목적어 트리플', up: true },
      { k: 'sg', x: 1450, y: 300, t: '상태 그래프', d: 'LangGraph 방식 · 노드 11개', up: true },
      { k: 'mcp', x: 1560, y: 585, t: 'MCP 도구', d: 'JSON-RPC 2.0 · stdio / HTTP' },
      { k: 'harness', x: 1320, y: 790, t: '하네스', d: '규칙 고정 · 출처 강제 · 검증' },
      { k: 'voice', x: 600, y: 790, t: '음성 입력', d: 'SpeechAnalyzer 받아쓰기' },
      { k: 'image', x: 360, y: 585, t: '이미지 첨부', d: 'Attachment + Vision OCR' },
    ];
    const times = { rag: cue('L04', 'rag'), kg: cue('L04', 'kg'), sg: cue('L04', 'sg'), mcp: cue('L04', 'mcp'), harness: cue('L04', 'harness'), image: cue('L04', 'fill') + 0.1, voice: cue('L04', 'fill') + 0.5 };
    Object.keys(times).forEach((k, i) => { times[k] = ev(times[k], 'star', i); });
    // ring
    const ring = nodes.map((n) => `${n.x},${n.y}`);
    nodes.forEach((n, i) => {
      const m = nodes[(i + 1) % nodes.length];
      const len = Math.hypot(m.x - n.x, m.y - n.y);
      const p = el('path', { d: `M${n.x} ${n.y} L${m.x} ${m.y}`, stroke: 'rgba(255,214,150,0.22)', 'stroke-width': 1.5, fill: 'none', 'stroke-dasharray': len, 'stroke-dashoffset': len }, svg);
      tl.to(p, { attr: { 'stroke-dashoffset': 0 }, duration: 1.2, ease: 'power1.inOut' }, cue('L04', 'fill') + 0.3 + i * 0.05);
    });
    nodes.forEach((n) => {
      const len = Math.hypot(n.x - C.x, n.y - C.y);
      const ex = C.x + (n.x - C.x) * 0.2, ey = C.y + (n.y - C.y) * 0.2;
      const p = el('path', { d: `M${ex} ${ey} L${n.x} ${n.y}`, stroke: 'rgba(255,214,150,0.55)', 'stroke-width': 1.6, fill: 'none', 'stroke-dasharray': len, 'stroke-dashoffset': len }, svg);
      tl.to(p, { attr: { 'stroke-dashoffset': 0 }, duration: 0.6, ease: 'power2.out' }, times[n.k] - 0.45);
      const st = el('div', { class: 'star', style: { left: n.x + 'px', top: n.y + 'px' } }, $('#s-stack'));
      tl.fromTo(st, { opacity: 0.22, scale: 0.7 }, { opacity: 1, scale: 1, duration: 0.5, ease: 'back.out(3)', immediateRender: false }, times[n.k]);
      const lab = el('div', { class: 'node', style: { left: n.x + 'px', top: (n.up ? n.y - 104 : n.y + 26) + 'px' }, html: `<div class="t">${n.t}</div><div class="d">${n.d}</div>` }, $('#s-stack'));
      gsap.set(lab, { opacity: 0 });
      show(lab, times[n.k] + 0.05, 0.5, { y: n.up ? -10 : 10 });
    });
    const lan = $('#stLantern');
    show(lan, s.start + 0.2, 0.9, { scale: 0.9 });
    show($('#stGlow'), s.start + 0.3, 1.2);
    show($('#stModel'), cue('L04', 'small') + 0.2, 0.6, { y: 10 });
  }

  // ================================================================= S4 MODES
  {
    const s = scene.modes;
    glowTo(s.start, 700, 520, 1000, 0.45);
    const win = $('#modesWin');
    const full = { cx: 800, cy: 512, s: 1180 / 1600 };
    cam(win, null, full);
    show(win, s.start + 0.05, 0.9, { x: -30 });
    cam(win, cue('L05', 'fast') - 0.1, { cx: 960, cy: 395, s: 0.96 }, 1.4);
    const fastBadge = hl(win, 428, 191, 92, 28);
    const skip1 = hl(win, 1240, 329, 350, 38), skip2 = hl(win, 1240, 414, 350, 38), gen = hl(win, 1240, 500, 350, 38, 'green');
    show(fastBadge, cue('L05', 'fast') + 0.6, 0.4); hide(fastBadge, cue('L05', 'direct') + 0.2);
    show(skip1, cue('L05', 'once') + 0.1, 0.35); show(skip2, cue('L05', 'once') + 0.35, 0.35);
    show(gen, cue('L05', 'direct'), 0.35);
    [skip1, skip2, gen].forEach((n) => hide(n, cue('L06', 'deep') - 0.1));
    const deepImg = $('#shotDeep');
    tl.to(deepImg, { opacity: 1, duration: 0.6, ease: 'power1.inOut' }, cue('L06', 'deep') - 0.2);
    cam(win, cue('L06', 'deep') - 0.2, { cx: 1128, cy: 430, s: 1.25 }, 1.4);
    const rw = hl(win, 1240, 329, 352, 86), gr = hl(win, 1240, 462, 352, 38), vf = hl(win, 1240, 590, 352, 38, 'green');
    show(rw, cue('L06', 'rewrite'), 0.4); show(gr, cue('L06', 'grade') + 0.1, 0.4); show(vf, cue('L06', 'verify'), 0.4);

    const bolt = '<svg width="30" height="34" viewBox="0 0 30 34"><path d="M17 2L4 20h10l-2 12 14-19H16z" fill="#ffd89a"/></svg>';
    const mag = '<svg width="32" height="32" viewBox="0 0 32 32"><circle cx="13" cy="13" r="9" fill="none" stroke="#ffd89a" stroke-width="3.4"/><path d="M20 20l9 9" stroke="#ffd89a" stroke-width="3.6" stroke-linecap="round"/></svg>';
    const arrow = '<i>→</i>';
    const mf = $('#mcFast'), md = $('#mcDeep');
    mf.style.top = '160px'; md.style.top = '492px';
    mf.innerHTML = `<div class="h">${bolt}빠른 답변</div><div class="flow"><b>검색 1회</b>${arrow}<b>초안 생성</b>${arrow}<b>규칙 검사</b></div>
      <div class="stats"><div class="stat"><div class="v">8.7<small>초</small></div><div class="n">실측 지연</div></div><div class="stat"><div class="v">1<small>회</small></div><div class="n">모델 호출</div></div></div>`;
    md.innerHTML = `<div class="h">${mag}심층 검색</div><div class="flow"><b>질의 재작성</b>${arrow}<b>다중 검색</b>${arrow}<b>관련성 채점</b>${arrow}<b>그래프 확장</b>${arrow}<b>초안 생성</b>${arrow}<b>규칙 + 근거 검증</b></div>
      <div class="stats"><div class="stat"><div class="v">~15<small>초</small></div><div class="n">실측 지연</div></div><div class="stat"><div class="v">6–9<small>회</small></div><div class="n">모델 호출</div></div></div>`;
    show(mf, cue('L05', 'fast') + 0.2, 0.6, { x: 30 });
    show(md, cue('L06', 'deep') + 0.2, 0.6, { x: 30 });
    tl.to(mf, { opacity: 0.5, duration: 0.5 }, cue('L06', 'deep') + 0.2);
  }

  // ================================================================= S5 AGENT GRAPH
  {
    const s = scene.graph;
    glowTo(s.start, 960, 500, 1150, 0.4);
    const svg = $('#agentSvg');
    const defs = el('defs', {}, svg);
    const mk = (id, color) => { const m = el('marker', { id, markerWidth: 10, markerHeight: 10, refX: 8, refY: 5, orient: 'auto', markerUnits: 'userSpaceOnUse' }, defs); el('path', { d: 'M0,0 L10,5 L0,10 z', fill: color }, m); };
    mk('ah', 'rgba(200,210,225,0.45)'); mk('ahA', '#ffb347');
    const BW = 252, BH = 104;
    const N = {
      intake: { x: 190, y: 330, t: '입력 분석', d: '언어 감지 · 질의 초기화', ms: '0 ms' },
      vision: { x: 490, y: 330, t: '이미지 이해', d: 'Vision 분류 + OCR', ms: '⏭ 첨부 이미지 없음', skip: true },
      rewrite: { x: 790, y: 330, t: '질의 재작성', d: '@Generable QueryRewrite', ms: '3,598 ms' },
      retrieve: { x: 1090, y: 330, t: '하이브리드 검색', d: '코사인 0.65 + 키워드 0.35', ms: '158 ms' },
      grade: { x: 1390, y: 330, t: '관련성 채점', d: 'RelevanceGrade × ≤5', ms: '7,200 ms' },
      graph: { x: 1690, y: 330, t: '그래프 확장', d: '1홉 사실 + 지식 부족 판정', ms: '1,070 ms · 근거 충분' },
      tools: { x: 1690, y: 660, t: '외부 도구(MCP)', d: '브리지 도구 + 지식 검색', ms: '' },
      learn: { x: 1390, y: 660, t: '지식 학습', d: '도구 결과 → 청크 + 그래프', ms: '' },
      generate: { x: 1090, y: 660, t: '초안 생성', d: '하네스 프롬프트 · 스트리밍', ms: '5,893 ms' },
      verify: { x: 790, y: 660, t: '하네스 검증', d: '규칙 검사 → 수정 · 근거 판정', ms: '2,341 ms' },
      finalize: { x: 490, y: 660, t: '마무리', d: '인용된 출처만 첨부', ms: '0 ms' },
      end: { x: 190, y: 660, t: 'END', d: '', ms: '', end: true },
    };
    const E = [];
    const edge = (a, b, d, cond = false, label = null, lx = 0, ly = 0, anchor = 'middle') => {
      const p = el('path', { d, fill: 'none', stroke: cond ? 'rgba(255,179,71,0.55)' : 'rgba(200,210,225,0.32)', 'stroke-width': 2, 'stroke-dasharray': cond ? '8 7' : 'none', 'marker-end': cond ? 'url(#ahA)' : 'url(#ah)' }, svg);
      let tx = null;
      if (label) tx = el('text', { x: lx, y: ly, fill: '#ffcf8a', 'font-size': 20, 'font-weight': 650, 'text-anchor': anchor, text: label }, svg);
      E.push({ a, b, p, tx, cond });
      return p;
    };
    const hw = BW / 2, hh = BH / 2;
    const rowEdge = (a, b) => edge(a, b, `M${N[a].x + hw} ${N[a].y} L${N[b].x - hw - 4} ${N[b].y}`);
    const backEdge = (a, b, endPad = 4) => edge(a, b, `M${N[a].x - hw} ${N[a].y} L${N[b].x + (N[b].end ? 70 : hw) + endPad} ${N[b].y}`);
    rowEdge('intake', 'vision'); rowEdge('vision', 'rewrite'); rowEdge('rewrite', 'retrieve'); rowEdge('retrieve', 'grade'); rowEdge('grade', 'graph');
    const cTools = edge('graph', 'tools', `M1790 ${330 + hh} L1790 ${660 - hh - 4}`, true, '지식 부족 + 심층 + MCP 도구', 1772, 540, 'end');
    const cEnough = edge('graph', 'generate', `M1590 ${330 + hh} L1590 470 L1090 470 L1090 ${660 - hh - 4}`, true, '충분', 1290, 456);
    backEdge('tools', 'learn'); backEdge('learn', 'generate'); backEdge('generate', 'verify'); backEdge('verify', 'finalize'); backEdge('finalize', 'end');
    E.forEach((e, i) => { gsap.set(e.p, { opacity: 0 }); if (e.tx) gsap.set(e.tx, { opacity: 0 }); tl.to(e.p, { opacity: 1, duration: 0.5 }, s.start + 0.5 + i * 0.04); if (e.tx) tl.to(e.tx, { opacity: 1, duration: 0.5 }, cue('L07', 'cond') - 0.2); });
    const NE = {};
    Object.entries(N).forEach(([k, n], i) => {
      const g = el('g', {}, svg);
      const w = n.end ? 140 : BW, h = n.end ? 72 : BH;
      const glow = el('rect', { x: n.x - w / 2 - 5, y: n.y - h / 2 - 5, width: w + 10, height: h + 10, rx: 22, fill: 'none', stroke: '#ffb347', 'stroke-width': 10, opacity: 0 }, g);
      const r = el('rect', { x: n.x - w / 2, y: n.y - h / 2, width: w, height: h, rx: 18, fill: n.end ? '#f4ecdf' : 'rgba(22,34,52,0.92)', stroke: n.end ? '#f4ecdf' : 'rgba(255,255,255,0.14)', 'stroke-width': 1.6 }, g);
      el('text', { x: n.x, y: n.end ? n.y + 8 : n.y - 6, 'text-anchor': 'middle', 'font-size': n.end ? 24 : 27, 'font-weight': 750, fill: n.end ? '#0b1626' : '#f4ecdf', text: n.t }, g);
      if (n.d) el('text', { x: n.x, y: n.y + 26, 'text-anchor': 'middle', 'font-size': 17.5, fill: '#8d98a8', text: n.d }, g);
      let ms = null;
      if (n.ms) ms = el('text', { x: n.x, y: n.y + h / 2 + 32, 'text-anchor': 'middle', 'font-size': 20, 'font-family': 'Plex Mono', 'font-weight': 500, fill: n.skip ? '#7f8a99' : '#ffd89a', text: n.ms, opacity: 0 }, g);
      gsap.set(g, { opacity: 0 });
      tl.to(g, { opacity: n.skip || k === 'tools' || k === 'learn' ? 0.55 : 1, duration: 0.5 }, s.start + 0.2 + i * 0.06);
      NE[k] = { g, r, glow, ms, n };
    });
    // title + footer
    const head = el('text', { x: 960, y: 178, 'text-anchor': 'middle', 'font-size': 34, 'font-family': 'Plex Mono', 'font-weight': 500, fill: '#f4ecdf', text: 'StateGraph<AgentState>' }, svg);
    const head2 = el('text', { x: 960, y: 222, 'text-anchor': 'middle', 'font-size': 22, fill: '#9aa5b5', text: '노드 11개 · 고정 간선 + 조건부 간선 · 최대 24스텝' }, svg);
    gsap.set([head, head2], { opacity: 0 });
    tl.to(head, { opacity: 1, duration: 0.6 }, cue('L07', 'langgraph'));
    tl.to(head2, { opacity: 1, duration: 0.6 }, cue('L07', 'eleven') - 0.1);
    const foot = $('#gFoot');
    foot.innerHTML = '<span class="chip">모든 노드가 TraceEvent를 보고</span><span class="chip cool">상태 · 요약 · 소요 ms → 추적 패널</span>';
    foot.style.top = '842px';
    show(foot, cue('L07', 'trace') - 0.1, 0.6, { y: 12 });
    // orb path through the deep-mode run in the screenshot (knowledge was sufficient → generate)
    const orb = $('#orb');
    const tc = q(cue('L07', 'cond'));
    const hop = 2 * EIGHTH;                      // one node per quarter note
    const t0 = tc - 5 * hop;
    const keys = [];
    ['intake', 'vision', 'rewrite', 'retrieve', 'grade', 'graph'].forEach((k, i) => { keys.push({ t: t0 + i * hop, x: N[k].x, y: N[k].y, k }); ev(t0 + i * hop, 'node', i); });
    const ta = tc + 2 * EIGHTH; // decision pause, then the "enough" branch
    keys.push({ t: ta, x: 1690, y: 330 });
    keys.push({ t: ta + 0.22, x: 1590, y: 400 });
    keys.push({ t: ta + 0.45, x: 1590, y: 470 });
    keys.push({ t: ta + 1.0, x: 1090, y: 470 });
    keys.push({ t: ta + 4 * EIGHTH, x: 1090, y: 660, k: 'generate' });
    keys.push({ t: ta + 6 * EIGHTH, x: 790, y: 660, k: 'verify' });
    keys.push({ t: ta + 8 * EIGHTH, x: 490, y: 660, k: 'finalize' });
    keys.push({ t: ta + 10 * EIGHTH, x: 190, y: 660, k: 'end' });
    [['generate', 4], ['verify', 6], ['finalize', 8], ['end', 10]].forEach(([k, m], i) => ev(ta + m * EIGHTH, 'node', 6 + i));
    keys.forEach((kf) => {
      if (!kf.k) return;
      const ne = NE[kf.k];
      if (kf.k === 'end') { tl.fromTo(ne.g, { scale: 1 }, { scale: 1.06, duration: 0.2, yoyo: true, repeat: 1, svgOrigin: `${kf.x} ${kf.y}`, immediateRender: false }, kf.t); return; }
      if (ne.n.skip) { tl.to(ne.ms, { opacity: 1, duration: 0.3 }, kf.t); return; }
      tl.to(ne.glow, { opacity: 0.22, duration: 0.25 }, kf.t);
      tl.to(ne.r, { attr: { stroke: '#ffb347', fill: 'rgba(70,52,30,0.92)' }, duration: 0.25 }, kf.t);
      if (ne.ms) tl.to(ne.ms, { opacity: 1, duration: 0.3 }, kf.t + 0.05);
    });
    tl.to(cEnough, { attr: { stroke: '#ffb347', 'stroke-width': 3 }, duration: 0.3 }, tc + 0.1);
    tl.to(cTools, { opacity: 0.45, duration: 0.3 }, tc + 0.5);
    per.push((t) => {
      if (t < keys[0].t - 0.3 || t > keys[keys.length - 1].t + 0.6) { orb.style.opacity = 0; return; }
      let i = 0; while (i < keys.length - 1 && t > keys[i + 1].t) i++;
      const a = keys[i], b = keys[Math.min(i + 1, keys.length - 1)];
      const k = b === a ? 0 : sm(clamp((t - a.t) / (b.t - a.t)));
      orb.style.left = lerp(a.x, b.x, k) + 'px'; orb.style.top = lerp(a.y, b.y, k) + 'px';
      orb.style.opacity = sm(ramp(t, keys[0].t - 0.3, keys[0].t)) * (1 - sm(ramp(t, keys[keys.length - 1].t, keys[keys.length - 1].t + 0.6)));
    });
  }

  // ================================================================= S6 RAG
  {
    const s = scene.rag;
    glowTo(s.start, 860, 480, 1100, 0.42);
    const doc = $('#docCard');
    show(doc, s.start + 0.1, 0.7, { x: -20 });
    const previews = [
      'Lantern(랜턴)은 Apple 기기 안에서만 동작하는 온디바이스 RAG 에이전트입니다…',
      'Lantern의 언어 모델은 Apple Foundation Models 프레임워크의 온디바이스 시스템 언어 모델…',
      'Lantern의 검색은 하이브리드입니다. Apple NaturalLanguage의 NLContextualEmbedding으로…',
      'Lantern은 LangGraph 방식의 상태 그래프(StateGraph)로 에이전트 흐름을 관리합니다…',
      'Lantern의 지식 그래프는 주어-술어-목적어 트리플로 사실을 저장합니다…',
      'Lantern은 MCP(Model Context Protocol) 클라이언트를 내장합니다…',
    ];
    const rr = rng(5);
    previews.forEach((p, i) => {
      const y = 104 + i * 76;
      const c = el('div', { class: 'chunk', style: { top: y + 'px' }, text: p }, doc);
      show(c, s.start + 0.5 + i * 0.12, 0.4, { x: -10 });
      const v = el('div', { class: 'vec', style: { top: 170 + y + 'px' } }, $('#vecs'));
      let bars = '';
      for (let j = 0; j < 72; j++) bars += `<i style="height:${8 + Math.round(Math.abs(Math.sin(j * 0.37 + i) * 22 + (rr() - 0.5) * 26))}px;opacity:${(0.45 + rr() * 0.55).toFixed(2)}"></i>`;
      v.innerHTML = bars;
      show(v, cue('L08', 'embed') - 0.3 + i * 0.1, 0.4, { x: -40 });
    });
    show($('#vecLbl'), cue('L08', 'embed') + 0.3, 0.5, { y: 10 });
    const f = $('#formula');
    show(f, cue('L08', 'hybrid') + 0.2, 0.7, { y: 16 });
    const tCos = $('#tCos'), tKey = $('#tKey');
    tl.to(tCos, { backgroundColor: 'rgba(255,179,71,0.22)', color: '#ffe2b0', duration: 0.35 }, cue('L08', 'cosine') - 0.1);
    tl.to('#lgCos', { color: '#ffd89a', duration: 0.35 }, cue('L08', 'cosine') - 0.1);
    tl.to(tKey, { backgroundColor: 'rgba(255,179,71,0.22)', color: '#ffe2b0', duration: 0.35 }, cue('L08', 'keyword') - 0.1);
    tl.to('#lgKey', { color: '#ffd89a', duration: 0.35 }, cue('L08', 'keyword') - 0.1);
    const topK = $('#topK'); gsap.set(topK, { opacity: 0 });
    tl.to(topK, { opacity: 1, duration: 0.5 }, cue('L08', 'pick') - 0.2);
    // gauge
    const g = $('#gauge');
    const X = (v) => 64 + (v - 0.30) * 1340;
    el('text', { x: 34, y: 48, 'font-size': 21, fill: '#7f8a99', 'font-weight': 500, text: '지식 부족 판정 · 최고 점수 기준' }, g);
    const zone = el('rect', { x: X(0.30), y: 120, width: X(0.45) - X(0.30), height: 60, fill: 'rgba(255,122,107,0.16)', opacity: 0 }, g);
    const zoneT = el('text', { x: X(0.30) + 14, y: 157, 'text-anchor': 'start', 'font-size': 19, 'font-weight': 700, fill: '#ffb0a6', text: '지식 부족', opacity: 0 }, g);
    el('line', { x1: X(0.30), y1: 180, x2: X(0.80), y2: 180, stroke: 'rgba(255,255,255,0.35)', 'stroke-width': 2 }, g);
    [0.3, 0.4, 0.5, 0.6, 0.7, 0.8].forEach((v) => {
      el('line', { x1: X(v), y1: 174, x2: X(v), y2: 186, stroke: 'rgba(255,255,255,0.35)', 'stroke-width': 2 }, g);
      el('text', { x: X(v), y: 212, 'text-anchor': 'middle', 'font-size': 18, 'font-family': 'Plex Mono', fill: '#7f8a99', text: v.toFixed(1) }, g);
    });
    const band = el('rect', { x: X(0.57), y: 150, width: X(0.71) - X(0.57), height: 30, rx: 6, fill: 'rgba(70,208,122,0.30)', opacity: 0 }, g);
    const bandT = el('text', { x: (X(0.57) + X(0.71)) / 2, y: 140, 'text-anchor': 'middle', 'font-size': 18, fill: '#9bf0bb', text: '관련 문서 0.57–0.71', opacity: 0 }, g);
    const unr = el('circle', { cx: X(0.41), cy: 180, r: 7, fill: '#bcc5d1', opacity: 0 }, g);
    const unrT = el('text', { x: X(0.41) - 14, y: 248, 'text-anchor': 'middle', 'font-size': 18, fill: '#bcc5d1', text: '무관 문서 ≈ 0.41', opacity: 0 }, g);
    const th = el('line', { x1: X(0.45), y1: 92, x2: X(0.45), y2: 196, stroke: '#ffb347', 'stroke-width': 3, 'stroke-dasharray': '104', 'stroke-dashoffset': '104' }, g);
    const thT = el('text', { x: X(0.45) + 10, y: 104, 'font-size': 20, 'font-weight': 700, fill: '#ffd89a', text: '문턱 0.45', opacity: 0 }, g);
    const mk = el('g', { opacity: 0 }, g);
    el('polygon', { points: `${X(0.42) - 10},${150} ${X(0.42) + 10},${150} ${X(0.42)},${168}`, fill: '#ff7a6b' }, mk);
    const mkT = el('text', { x: X(0.42) + 58, y: 280, 'font-size': 19, fill: '#ffb0a6', 'font-weight': 600, text: '“1234 더하기 4321은 얼마야?” → 0.42  · 지식 부족 감지', opacity: 0 }, g);
    show(g, cue('L09', 'best') - 0.3, 0.6, { y: 16 });
    tl.to([band, bandT, unr, unrT], { opacity: 1, duration: 0.5, stagger: 0.08 }, cue('L09', 'best') + 0.2);
    tl.to(th, { attr: { 'stroke-dashoffset': 0 }, duration: 0.5, ease: 'power2.out' }, cue('L09', 'thresh') - 0.1);
    tl.to(thT, { opacity: 1, duration: 0.4 }, cue('L09', 'thresh') + 0.1);
    tl.to([zone, zoneT], { opacity: 1, duration: 0.5 }, cue('L09', 'gap') - 0.3);
    tl.fromTo(mk, { opacity: 0, y: -30 }, { opacity: 1, y: 0, duration: 0.5, ease: 'bounce.out', immediateRender: false }, cue('L09', 'judge') - 0.4);
    tl.to(mkT, { opacity: 1, duration: 0.4 }, cue('L09', 'judge'));
    tl.to(f, { opacity: 0.55, duration: 0.5 }, cue('L09', 'best'));
  }

  // ================================================================= S7 KNOWLEDGE GRAPH
  {
    const s = scene.kg;
    glowTo(s.start, 600, 520, 900, 0.5);
    const svg = $('#kgSvg');
    const P = { '검색': [425, 27], 'rag': [199, 100], '이미지': [648, 100], '모델': [424, 237], 'lantern': [60, 291], '기기': [302, 288], '코드': [545, 288], '전송': [788, 291],
      '트리플': [252, 410], 'mcp': [596, 410], 'Core ML': [60, 527], '모드': [302, 531], '규칙': [545, 531], '근거': [788, 527], '노드': [424, 580], '그래프': [199, 718], '사실': [648, 718], '서버': [424, 792] };
    const S2 = (p) => [170 + p[0] * 0.95, 140 + p[1] * 0.95];
    const EDG = [['검색', '노드'], ['rag', '모델'], ['모델', '기기'], ['모델', '코드'], ['lantern', '코드'], ['코드', 'Core ML'], ['이미지', '규칙'], ['전송', 'mcp'], ['mcp', '서버'], ['트리플', '모드'], ['모드', '사실'], ['노드', '그래프'], ['규칙', '근거']];
    const nb = new Set(['모델', 'rag', '기기', '코드']);
    line.L10.cues.neighbor = ev(cue('L10', 'neighbor'), 'kg');
    const edges = EDG.map(([a, b], i) => {
      const [x1, y1] = S2(P[a]), [x2, y2] = S2(P[b]);
      const len = Math.hypot(x2 - x1, y2 - y1);
      const p = el('path', { d: `M${x1} ${y1} L${x2} ${y2}`, stroke: 'rgba(255,214,150,0.5)', 'stroke-width': 1.8, fill: 'none', 'stroke-dasharray': len, 'stroke-dashoffset': len }, svg);
      tl.to(p, { attr: { 'stroke-dashoffset': 0 }, duration: 0.7, ease: 'power1.inOut' }, cue('L10', 'triple') - 0.3 + i * 0.07);
      const hot = a === '모델' || b === '모델';
      tl.to(p, hot ? { attr: { stroke: '#ffcf80', 'stroke-width': 3 }, duration: 0.4 } : { opacity: 0.3, duration: 0.4 }, cue('L10', 'neighbor'));
      return p;
    });
    const order = Object.keys(P).sort(() => 0);
    const rr = rng(11);
    order.forEach((name, i) => {
      const [x, y] = S2(P[name]);
      const g = el('g', {}, svg);
      const halo = el('circle', { cx: x, cy: y, r: 16, fill: 'rgba(255,190,110,0.18)' }, g);
      const dot = el('circle', { cx: x, cy: y, r: 6.5, fill: '#ffe2ad' }, g);
      const lab = el('text', { x, y: y + 36, 'text-anchor': 'middle', 'font-size': 23, 'font-weight': 600, fill: '#d5dce6', text: name }, g);
      gsap.set(g, { opacity: 0 });
      tl.to(g, { opacity: 1, duration: 0.5 }, s.start + 0.3 + rr() * 1.3);
      if (name === '모델') {
        tl.to(halo, { attr: { r: 30 }, fill: 'rgba(255,190,110,0.34)', duration: 0.5 }, cue('L10', 'neighbor'));
        tl.to(dot, { attr: { r: 9 }, duration: 0.5 }, cue('L10', 'neighbor'));
        tl.to(lab, { attr: { fill: '#ffd89a' }, duration: 0.4 }, cue('L10', 'neighbor'));
      } else if (nb.has(name)) {
        tl.to(halo, { attr: { r: 22 }, fill: 'rgba(255,190,110,0.28)', duration: 0.5 }, cue('L10', 'neighbor') + 0.2);
        tl.to(lab, { attr: { fill: '#ffe9c6' }, duration: 0.4 }, cue('L10', 'neighbor') + 0.2);
      } else {
        tl.to(g, { opacity: 0.38, duration: 0.5 }, cue('L10', 'neighbor'));
      }
    });
    const tc = $('#tripleCard');
    show(tc, cue('L10', 'subj') - 0.5, 0.6, { y: 16 });
    const hlCell = (id, at) => tl.to(`#${id} .v`, { borderColor: 'rgba(255,179,71,0.9)', backgroundColor: 'rgba(255,179,71,0.14)', duration: 0.3 }, at);
    hlCell('trS', cue('L10', 'subj')); hlCell('trP', cue('L10', 'pred')); hlCell('trO', cue('L10', 'obj'));
    const stat = $('#kgStat'); stat.style.left = '1150px'; stat.style.top = '508px';
    show(stat, cue('L10', 'triple'), 0.5);
    const fc = $('#factsCard');
    show(fc, cue('L10', 'neighbor') - 0.4, 0.6, { y: 16 });
    ['#f1', '#f2', '#f3'].forEach((id, i) => tl.to(id, { autoAlpha: 1, duration: 0.4 }, cue('L10', 'evidence') - 0.2 + i * 0.25));
  }

  // ================================================================= S8 MCP + LEARNING
  {
    const s = scene.mcp;
    glowTo(s.start, 700, 520, 1000, 0.42);
    const win = $('#mcpWin');
    cam(win, null, { cx: 800, cy: 512, s: 1180 / 1600 });
    show(win, s.start + 0.05, 0.9, { x: -30 });
    cam(win, cue('L11', 'gap') - 0.1, { cx: 978, cy: 520, s: 0.945 }, 1.5);
    const hGap = hl(win, 1240, 471, 352, 38), hTool = hl(win, 1240, 514, 352, 38), hLearn = hl(win, 1240, 556, 352, 56, 'green');
    const hAns = hl(win, 362, 790, 380, 34, 'green'), hLog = hl(win, 1238, 762, 180, 62, 'green');
    show(hGap, cue('L11', 'gap') + 0.6, 0.4); show(hTool, cue('L11', 'tool'), 0.4);
    hide(hGap, cue('L12', 'learned')); hide(hTool, cue('L12', 'learned'));
    show(hLearn, cue('L12', 'store') - 0.3, 0.4);
    show(hAns, cue('L12', 'local') + 0.1, 0.4); show(hLog, cue('L12', 'local') + 0.3, 0.4);
    // JSON-RPC sequence card
    const sc = $('#seqCard');
    sc.innerHTML = '<div class="hdr"><span style="position:absolute;left:100px;transform:translateX(-50%)">Lantern</span><span style="position:absolute;left:420px;transform:translateX(-50%);color:var(--amber2)">MCP 서버</span></div>' +
      '<svg width="520" height="470" style="position:absolute;left:0;top:0"><line x1="100" y1="64" x2="100" y2="410" stroke="rgba(255,255,255,0.14)" stroke-dasharray="5 6" stroke-width="2"/><line x1="420" y1="64" x2="420" y2="410" stroke="rgba(255,255,255,0.14)" stroke-dasharray="5 6" stroke-width="2"/></svg>' +
      '<div style="position:absolute;left:0;right:0;bottom:22px;display:flex;justify-content:center;gap:10px"><span class="chip cool" style="font-size:18px;padding:6px 12px">JSON-RPC 2.0</span><span class="chip cool" style="font-size:18px;padding:6px 12px">stdio · Streamable HTTP</span></div>';
    const msgs = [
      { y: 96, dir: 1, t: 'initialize · tools/list', at: cue('L11', 'mcp') - 0.2 },
      { y: 166, dir: -1, t: 'tools: add, echo', at: cue('L11', 'mcp') + 0.3 },
      { y: 236, dir: 1, t: 'tools/call  add', at: cue('L11', 'call') - 0.2, hot: true },
      { y: 306, dir: -1, t: '“5555”', at: ev(cue('L11', 'call') + 0.5, 'result'), hot: true },
    ];
    msgs.forEach((m) => {
      const d = el('div', { class: 'msg', style: { top: m.y + 'px', left: '100px', width: '320px' } }, sc);
      const col = m.hot ? '#ffb347' : 'rgba(200,210,225,0.55)';
      d.innerHTML = `<div class="tx" style="color:${m.hot ? '#ffd89a' : '#bcc5d1'}">${m.t}</div>` +
        `<svg width="320" height="20" style="position:absolute;left:0;top:30px"><line x1="${m.dir > 0 ? 4 : 316}" y1="10" x2="${m.dir > 0 ? 306 : 14}" y2="10" stroke="${col}" stroke-width="2.4" ${m.dir < 0 ? 'stroke-dasharray="7 6"' : ''}/>` +
        `<path d="${m.dir > 0 ? 'M306 4 L316 10 L306 16 z' : 'M14 4 L4 10 L14 16 z'}" fill="${col}"/></svg>`;
      show(d, m.at, 0.45, { x: m.dir * -20 });
    });
    show(sc, s.start + 0.6, 0.7, { x: 30 });
    const st = $('#storeCard'), nd = $('#newDoc');
    show(st, cue('L12', 'learned') - 0.2, 0.6, { y: 16 });
    gsap.set(nd, { autoAlpha: 0 });
    tl.fromTo(nd, { autoAlpha: 0, x: 60 }, { autoAlpha: 1, x: 0, duration: 0.6, ease: 'power3.out', immediateRender: false }, ev(cue('L12', 'store') - 0.2, 'learn'));
    tl.to(nd, { borderColor: 'rgba(255,179,71,0.8)', backgroundColor: 'rgba(255,179,71,0.10)', boxShadow: '0 0 24px rgba(255,179,71,0.3)', duration: 0.4 }, cue('L12', 'next') - 0.1);
  }

  // ================================================================= S9 HARNESS
  {
    const s = scene.harness;
    glowTo(s.start, 640, 520, 1000, 0.42);
    const win = $('#hWin');
    cam(win, null, { cx: 800, cy: 512, s: 1060 / 1600 });
    show(win, s.start + 0.05, 0.9, { x: -30 });
    cam(win, cue('L13', 'harness') - 0.2, { cx: 950, cy: 640, s: 1.0 }, 1.4);
    const hp = hl(win, 510, 389, 882, 44), hr = hl(win, 510, 585, 882, 322), hc = hl(win, 510, 435, 882, 44);
    show(hp, cue('L13', 'persona'), 0.35); hide(hp, cue('L13', 'rules') + 0.1);
    show(hr, cue('L13', 'rules') + 0.05, 0.35); hide(hr, cue('L13', 'cite'));
    show(hc, cue('L13', 'cite'), 0.35);
    const cc = $('#checkCard');
    cc.innerHTML = '<div class="label">하네스 검증 · 출력 검사</div>' +
      '<div class="draft">랜턴의 검색은 하이브리드입니다 <span class="cite" id="c1">[2]</span>. 임베딩 자산이 없으면 해싱 n-gram 폴백으로 동작합니다 <span class="cite" id="c3">[3]</span><span class="cite" id="c3b" style="position:absolute;opacity:0">[2]</span>.</div>' +
      '<div class="srcs"><span class="label">제공된 근거</span><span class="chip cool" style="font-size:19px;padding:5px 12px">[1]</span><span class="chip cool" style="font-size:19px;padding:5px 12px">[2]</span></div>' +
      '<div class="badges"><span class="chip red" id="bGhost">존재하지 않는 출처 번호 인용</span><span class="chip" id="bFix">규칙 수정 1회 → 같은 근거로 다시 쓰기</span><span class="chip green" id="bPass">규칙 통과 · 근거 검증 통과</span></div>';
    show(cc, cue('L13', 'cite') - 0.3, 0.6, { x: 30 });
    ['#bGhost', '#bFix', '#bPass'].forEach((id) => gsap.set(id, { autoAlpha: 0 }));
    tl.to('#c3', { backgroundColor: 'rgba(255,122,107,0.25)', color: '#ffb0a6', duration: 0.3 }, cue('L13', 'ghost'));
    show($('#bGhost'), cue('L13', 'ghost') + 0.15, 0.4, { x: -10 });
    show($('#bFix'), cue('L13', 'catch'), 0.4, { x: -10 });
    tl.to('#c3', { autoAlpha: 0, duration: 0.25 }, cue('L13', 'catch') + 0.2);
    // place the corrected citation exactly where [3] sat
    per.push(() => { const a = document.getElementById('c3'), b = document.getElementById('c3b'); if (a && b && !b.dataset.p) { b.style.left = a.offsetLeft + 'px'; b.style.top = a.offsetTop + 'px'; b.dataset.p = 1; } });
    tl.to('#c3b', { opacity: 1, color: '#9bf0bb', backgroundColor: 'rgba(70,208,122,0.18)', duration: 0.3 }, cue('L13', 'catch') + 0.35);
    show($('#bPass'), ev(cue('L13', 'rewrite') + 0.2, 'pass'), 0.4, { x: -10 });
  }

  // ================================================================= S10 IMAGE + VOICE
  {
    const s = scene.multi;
    glowTo(s.start, 960, 560, 950, 0.5);
    const bar = $('#inputBar');
    show(bar, s.start + 0.1, 0.8, { y: 30 });
    const at = $('#attach');
    at.style.left = '330px'; at.style.top = '250px';
    const ai = $('#attachInfo'); ai.style.left = '660px'; ai.style.top = '270px';
    tl.to('#btnImg', { backgroundColor: '#6a4a1e', boxShadow: '0 0 0 2px #ffb347, 0 0 24px rgba(255,179,71,0.6)', duration: 0.3 }, cue('L14', 'image') - 0.2);
    tl.to('#btnImg', { backgroundColor: '#2f2f33', boxShadow: '0 0 0 0px #ffb347', duration: 0.5 }, cue('L14', 'sees') + 0.4);
    tl.fromTo(at, { autoAlpha: 0, x: 560 - 480, y: 608 - 335, scale: 0.2 }, { autoAlpha: 1, x: 0, y: 0, scale: 1, duration: 0.8, ease: 'power3.out', immediateRender: false }, cue('L14', 'image') + 0.05);
    show(ai, cue('L14', 'sees') - 0.3, 0.5, { x: -12 });
    const wv = $('#wave'); wv.style.left = '1150px'; wv.style.top = '250px'; wv.style.width = '520px';
    const vi = $('#voiceInfo'); vi.style.left = '1150px'; vi.style.top = '430px';
    const bars = Array.from({ length: 38 }, () => el('i', {}, wv));
    tl.to('#btnMic', { backgroundColor: '#6a4a1e', boxShadow: '0 0 0 2px #ffb347, 0 0 24px rgba(255,179,71,0.6)', duration: 0.3 }, cue('L14', 'voice') - 0.2);
    show(wv, cue('L14', 'voice') - 0.1, 0.4);
    show(vi, cue('L14', 'voice') + 0.3, 0.5, { y: 10 });
    const t0 = cue('L14', 'voice'), t1 = s.end;
    per.push((t) => {
      const live = t > t0 - 0.2 && t < t1 + 0.5;
      if (!live) return;
      bars.forEach((b, i) => {
        const e = 0.25 + 0.75 * Math.abs(Math.sin(t * 5.1 + i * 0.6) * Math.sin(t * 2.3 + i * 0.23));
        b.style.height = (10 + 110 * e * (0.6 + 0.4 * Math.sin(i * 0.9))) + 'px';
      });
    });
    const text = '이 그림에서 하네스는 어디에 있어?';
    const typed = $('#typed'), ph = $('#ph'), caret = $('#caret');
    const ts = cue('L14', 'transcribe') - 0.6;
    per.push((t) => {
      const n = Math.floor(clamp((t - ts) / 1.5) * text.length);
      typed.textContent = text.slice(0, n);
      ph.style.display = n > 0 ? 'none' : 'inline';
      caret.style.opacity = t > s.start + 0.5 && (Math.floor(t * 2.2) % 2 === 0 || (t > ts && t < ts + 1.6)) ? 1 : 0;
    });
  }

  // ================================================================= S11 OUTRO
  {
    const s = scene.outro;
    glowTo(s.start, 960, 320, 820, 0.95, 1.6);
    show($('#oIcon'), s.start + 0.2, 1.2, { scale: 0.92, y: 16 });
    show($('#oGlow'), s.start + 0.2, 1.4);
    gsap.set('#oTitle', { autoAlpha: 0 });
    tl.fromTo('#oTitle', { autoAlpha: 0, y: 20, letterSpacing: '0.06em' }, { autoAlpha: 1, y: 0, letterSpacing: '0.005em', duration: 1.2, ease: 'power3.out', immediateRender: false }, ev(cue('L15', 'mine') + 0.1, 'title'));
    show($('#oTag'), cue('L15', 'lamp') - 0.2, 0.8, { y: 12 });
    show($('#oChips'), cue('L15', 'lantern') + 0.3, 0.7, { y: 12 });
    show($('#oUrl'), cue('L15', 'lantern') + 0.6, 0.7, { y: 12 });
    tl.to('#fadeBlack', { opacity: 1, duration: 1.4, ease: 'sine.in' }, TL.duration - 1.5);
  }

  // ---------------------------------------------------------------- seek
  window.DURATION = TL.duration;
  window.seek = function (t) {
    tl.seek(Math.max(0, Math.min(t, TL.duration)), false);
    drawSky(t);
    for (const f of per) f(t);
  };
  const imgs = Array.from(document.images).map((im) => (im.complete ? Promise.resolve() : new Promise((r) => { im.onload = r; im.onerror = r; })));
  window.ready = Promise.all([document.fonts.ready, ...imgs]).then(() => { window.seek(0); return true; });
})();
