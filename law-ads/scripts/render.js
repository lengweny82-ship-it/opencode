const cImport = require('@sparticuz/chromium');
const chromium = cImport.default || cImport;
const puppeteer = require('puppeteer-core');
const sharp = require('sharp');
const path = require('path');
const fs = require('fs');

const ROOT = path.resolve(__dirname, '..');
const FILES = ['posters-a.html', 'posters-b.html'];

(async () => {
  fs.mkdirSync(path.join(ROOT, 'exports', 'thumb'), { recursive: true });
  const execPath = await chromium.executablePath();
  const browser = await puppeteer.launch({
    args: [...chromium.args, '--no-sandbox', '--disable-dev-shm-usage', '--force-color-profile=srgb'],
    executablePath: execPath,
    headless: true,
    env: { ...process.env, LD_LIBRARY_PATH: '/tmp/al2023/lib:' + (process.env.LD_LIBRARY_PATH || '') },
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1180, height: 1500, deviceScaleFactor: 2 });

  const made = [];
  for (const f of FILES) {
    const url = 'file://' + path.join(ROOT, f);
    await page.goto(url, { waitUntil: 'networkidle0', timeout: 120000 });
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.all([...document.images].map(im => im.decode().catch(() => {})));
    });
    await new Promise(r => setTimeout(r, 300));
    const posters = await page.$$('.poster');
    console.log(f, '→', posters.length, 'posters');
    for (const el of posters) {
      const name = await el.evaluate(n => n.dataset.name);
      await el.evaluate(n => n.scrollIntoView({ block: 'start' }));
      await new Promise(r => setTimeout(r, 150));
      const pngPath = path.join(ROOT, 'exports', name + '.png');
      await el.screenshot({ path: pngPath, type: 'png' });
      const jpgPath = path.join(ROOT, 'exports', name + '.jpg');
      await sharp(pngPath).jpeg({ quality: 90, mozjpeg: true }).toFile(jpgPath);
      await sharp(pngPath).resize({ width: 720 }).jpeg({ quality: 82, mozjpeg: true }).toFile(path.join(ROOT, 'exports', 'thumb', name + '.jpg'));
      const meta = await sharp(pngPath).metadata();
      console.log(' ', name, meta.width + '×' + meta.height);
      made.push(name);
    }
  }
  await browser.close();
  console.log('DONE:', made.length, 'ads');
})().catch(e => { console.error('FAIL', e); process.exit(1); });
