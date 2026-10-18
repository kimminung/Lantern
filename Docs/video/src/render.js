// Frame-accurate renderer for the Lantern intro (serves the repository root, opens Docs/video/src/index.html).
//   node render.js stills <dir> t1 t2 ...         PNG stills
//   node render.js video <out.mkv> [fps] [from] [to]  near-lossless master (x264 crf 8)
//   node render.js events <out.json>               light-up events on the 8th-note grid (read by audio/music.py)
const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path'), { spawn } = require('child_process');
const ROOT = path.resolve(__dirname, '../../..');   // repository root
const PAGE = '/Docs/video/src/index.html';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.json': 'application/json' };
function serve() {
  return new Promise((res) => {
    const srv = http.createServer((req, rsp) => {
      const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]));
      fs.readFile(p, (e, d) => { if (e) { rsp.writeHead(404); rsp.end(); return; } rsp.writeHead(200, { 'Content-Type': MIME[path.extname(p)] || 'application/octet-stream' }); rsp.end(d); });
    }).listen(0, '127.0.0.1', () => res(srv));
  });
}
(async () => {
  const [mode, out, ...rest] = process.argv.slice(2);
  const srv = await serve();
  const port = srv.address().port;
  const browser = await chromium.launch({ args: ['--disable-gpu', '--font-render-hinting=none', '--force-color-profile=srgb'] });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
  page.on('console', (m) => { if (m.type() === 'error') console.error('PAGE:', m.text()); });
  page.on('pageerror', (e) => console.error('PAGEERR:', e.message));
  const query = mode === 'video' ? (rest[3] || '') : (process.env.Q || '');
  await page.goto(`http://127.0.0.1:${port}${PAGE}${query}`);
  await page.evaluate(() => window.ready);
  const dur = await page.evaluate(() => window.DURATION);
  const client = await page.context().newCDPSession(page);
  const shot = async () => Buffer.from((await client.send('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true })).data, 'base64');
  if (mode === 'events') {
    const evs = await page.evaluate(() => window.EVENTS);
    fs.writeFileSync(out, JSON.stringify({ duration: dur, events: evs.sort((a, b) => a.t - b.t) }, null, 1));
    console.log('events', evs.length);
  } else if (mode === 'stills') {
    fs.mkdirSync(out, { recursive: true });
    for (const ts of rest) {
      const t = parseFloat(ts);
      await page.evaluate((t) => window.seek(t), t);
      fs.writeFileSync(path.join(out, `t${t.toFixed(2).padStart(7, '0')}.png`), await shot());
    }
  } else if (mode === 'video') {
    const fps = parseFloat(rest[0] || '30');
    const from = parseFloat(rest[1] || '0'), to = Math.min(parseFloat(rest[2] || String(dur)), dur);
    const n = Math.round((to - from) * fps);
    const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
      '-c:v', 'libx264', '-preset', 'fast', '-crf', '8', '-pix_fmt', 'yuv420p', '-r', String(fps), out], { stdio: ['pipe', 'inherit', 'inherit'] });
    const t0 = Date.now();
    for (let i = 0; i < n; i++) {
      const t = from + i / fps;
      await page.evaluate((t) => window.seek(t), t);
      const buf = await shot();
      if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once('drain', r));
      if (i % 150 === 0) console.log(`frame ${i}/${n}  t=${t.toFixed(2)}  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
    }
    ff.stdin.end();
    await new Promise((r) => ff.on('close', r));
    console.log('done', n, 'frames', ((Date.now() - t0) / 1000).toFixed(0) + 's');
  }
  await browser.close(); srv.close();
})().catch((e) => { console.error(e); process.exit(1); });
