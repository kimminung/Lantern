// README GIF: render highlight segments (silent, short headline captions instead of narration).
//   node render_gif.js <outDir>   → <outDir>/sNN_FFFF.png at 15 fps + segments.json
// then: python3 make_gif.py <outDir> <out.gif> [width] [colors]
const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '../../..');   // repository root
const PAGE = '/Docs/video/src/index.html';
const FPS = 15;
// times are on the video timeline; `hold` repeats one frame
const SEGMENTS = [
  { t0: 8.7, hold: 1.4, cap: null },
  { t0: 20.6, t1: 23.4, cap: '문서 · 대화 · 임베딩은 기기 안의 JSON으로 — 네트워크 요청 0' },
  { t0: 28.0, t1: 32.9, cap: '작은 온디바이스 모델 위에 RAG · 지식 그래프 · 상태 그래프 · MCP · 하네스' },
  { t0: 35.5, t1: 37.3, cap: '빠른 답변 — 검색 1회, 약 9초' },
  { t0: 39.3, t1: 41.9, cap: '심층 검색 — 재작성 · 채점 · 근거 검증, 약 15초' },
  { t0: 47.4, t1: 53.9, cap: 'LangGraph 방식 StateGraph — 노드 11개 · 조건부 간선' },
  { t0: 63.2, t1: 66.6, cap: '하이브리드 검색 — 최고 점수 0.45 미만이면 지식 부족' },
  { t0: 72.9, t1: 75.0, cap: '질문 속 개념의 1홉 이웃 사실을 근거에 추가' },
  { t0: 79.9, t1: 81.9, cap: '지식이 부족하면 MCP 도구를 직접 호출' },
  { t0: 83.0, t1: 85.4, cap: '알아낸 사실은 새 지식으로 저장 — 다음엔 기기 안에서' },
  { t0: 92.0, t1: 95.3, cap: '하네스 — 없는 출처 인용을 잡아 다시 쓰게' },
  { t0: 107.7, hold: 2.6, cap: null },
];
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' };
(async () => {
  const out = process.argv[2];
  fs.mkdirSync(out, { recursive: true });
  const srv = await new Promise((res) => { const s = http.createServer((q, r) => { const p = path.join(ROOT, decodeURIComponent(q.url.split('?')[0])); fs.readFile(p, (e, d) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': MIME[path.extname(p)] || 'application/octet-stream' }); r.end(d); }); }).listen(0, '127.0.0.1', () => res(s)); });
  const browser = await chromium.launch({ args: ['--disable-gpu', '--font-render-hinting=none', '--force-color-profile=srgb'] });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  page.on('pageerror', (e) => console.error('[pageerror]', e.message));
  await page.goto(`http://127.0.0.1:${srv.address().port}${PAGE}?gif=1`);
  await page.evaluate(() => window.ready);
  await page.evaluate(() => document.body.classList.add('gif'));
  const cdp = await page.context().newCDPSession(page);
  const meta = [];
  for (let si = 0; si < SEGMENTS.length; si++) {
    const s = SEGMENTS[si];
    const n = Math.round((s.hold !== undefined ? s.hold : s.t1 - s.t0) * FPS);
    meta.push({ i: si, frames: n, cap: s.cap });
    for (let f = 0; f < n; f++) {
      const t = s.hold !== undefined ? s.t0 : s.t0 + f / FPS;
      const local = f / FPS, dur = n / FPS;
      const a = s.cap ? Math.max(0, Math.min(1, local / 0.25, (dur - local) / 0.2)) : 0;
      await page.evaluate(([t, cap, a]) => { window.seek(t); window.gifCap(cap, a); }, [t, s.cap, a]);
      const { data } = await cdp.send('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true });
      fs.writeFileSync(path.join(out, `s${String(si).padStart(2, '0')}_${String(f).padStart(4, '0')}.png`), Buffer.from(data, 'base64'));
    }
    console.log('segment', si, n, 'frames');
  }
  fs.writeFileSync(path.join(out, 'segments.json'), JSON.stringify({ fps: FPS, segments: meta }, null, 1));
  await browser.close(); srv.close();
})().catch((e) => { console.error(e); process.exit(1); });
