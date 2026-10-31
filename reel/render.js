// Usage: node render.js reel.html out.mp4 [fps]      -> renders the full video (silent)
//        node render.js reel.html stills t1,t2,...   -> writes still_<t>.png for review
const { chromium } = require('playwright');
const { spawn } = require('child_process');
const path = require('path');

(async () => {
  const [html, out, arg] = process.argv.slice(2);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1080, height: 1920 } });
  page.on('pageerror', e => { console.error('page error:', e.message); process.exit(1); });
  await page.goto('file://' + path.resolve(html));
  await page.waitForFunction('window.ready === true');

  if (out === 'stills') {
    for (const t of arg.split(',').map(Number)) {
      await page.evaluate(t => render(t), t);
      await page.screenshot({ path: path.join(path.dirname(html), `still_${t}.png`) });
    }
  } else {
    const fps = Number(arg || 30);
    const dur = await page.evaluate(() => DURATION);
    const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', out], { stdio: ['pipe', 'inherit', 'inherit'] });
    const n = Math.round(dur * fps);
    for (let k = 0; k < n; k++) {
      await page.evaluate(t => render(t), k / fps);
      const buf = await page.screenshot({ type: 'png' });
      if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    }
    ff.stdin.end();
    await new Promise(r => ff.on('close', r));
    console.log(`rendered ${n} frames -> ${out}`);
  }
  await browser.close();
})();
