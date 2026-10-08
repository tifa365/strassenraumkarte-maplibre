#!/usr/bin/env node
// Capture the MapLibre preview for an XYZ tile block at the exact pixel size
// of the matching QGIS raster tiles, for pixel comparison.
//
// Usage:
//   node scripts/capture_maplibre_block.js Z X0 Y0 NX NY OUT.png [options]
//   node scripts/capture_maplibre_block.js --check-only [options]
//
// Options: --zoom-offset N (default -1)  --maplibre X.Y.Z  --timeout SEC (240)
//          --allow-errors  --base URL  --hide id1,id2,...  (hide layers, for debugging;
//          an id ending in * hides every layer whose id starts with it)
//          --paint '{"layer-id":{"paint-prop":value,...},...}'  (override paint properties,
//          for experiments without editing the style)
//
// Z is the XYZ raster zoom (256px tiles). MapLibre uses 512px world tiles, so
// the default MapLibre zoom is Z-1 (one CSS px == one raster-tile px).
// Exits 1 when MapLibre reports any style or tile error (--allow-errors
// downgrades that to a warning), so a style MapLibre rejects cannot pass
// unnoticed. --check-only loads the style over a small default block and
// exits without taking a screenshot.
// Requires: web/ served on :8080 (python3 -m http.server 8080 --directory web)
// and Martin on :3000 (render/serve_mvt.sh). puppeteer-core is resolved from
// a local/global install (see below).
const path = require('path');
const { execSync } = require('child_process');
const globalRoot = execSync('npm root -g').toString().trim();
// Resolve puppeteer-core from the local install, the global root, or the one
// bundled with the globally installed @modelcontextprotocol/server-puppeteer.
const puppeteer = [
  'puppeteer-core',
  path.join(globalRoot, 'puppeteer-core'),
  path.join(globalRoot, '@modelcontextprotocol/server-puppeteer/node_modules/puppeteer-core'),
].reduce((found, id) => found || (() => { try { return require(id); } catch { return null; } })(), null);
if (!puppeteer) { console.error('puppeteer-core not found'); process.exit(2); }
const fs = require('fs');

const args = process.argv.slice(2);
const flag = (name, dflt) => {
  const i = args.indexOf(name);
  if (i < 0) return dflt;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const boolFlag = name => {
  const i = args.indexOf(name);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
};
// Parse every option before reading the positional arguments.
const zoomOffset = Number(flag('--zoom-offset', -1));
const mlVersion = flag('--maplibre', '');
const base = flag('--base', 'http://127.0.0.1:8080');
const timeoutSec = Number(flag('--timeout', 240));
const hide = flag('--hide', '').split(',').filter(Boolean);
const paintOverrides = JSON.parse(flag('--paint', '{}'));
const allowErrors = boolFlag('--allow-errors');
const checkOnly = boolFlag('--check-only');
let [Z, X0, Y0, NX, NY, OUT] = args;
if (checkOnly) {
  [Z, X0, Y0, NX, NY] = [17, 70426, 43011, 2, 2];
} else if (!OUT) {
  console.error('usage: capture_maplibre_block.js Z X0 Y0 NX NY OUT.png [options] | --check-only [options]');
  process.exit(2);
}
const z = Number(Z), x0 = Number(X0), y0 = Number(Y0), nx = Number(NX), ny = Number(NY);

// Centre of the block in lon/lat (Web Mercator tile maths).
const n = 2 ** z;
const cx = x0 + nx / 2, cy = y0 + ny / 2;
const lon = (cx / n) * 360 - 180;
const lat = (Math.atan(Math.sinh(Math.PI * (1 - (2 * cy) / n))) * 180) / Math.PI;

const chromeDir = path.join(process.env.HOME, '.cache/puppeteer/chrome');
const chrome = fs.readdirSync(chromeDir).sort().pop();
const executablePath = path.join(
  chromeDir, chrome, 'chrome-mac-arm64',
  'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

(async () => {
  const browser = await puppeteer.launch({
    executablePath,
    headless: true,
    protocolTimeout: 300000,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
           '--ignore-gpu-blocklist'],
  });
  const page = await browser.newPage();
  if (mlVersion) {
    // Test the preview against another MapLibre GL JS release without editing index.html.
    await page.setRequestInterception(true);
    page.on('request', r => {
      const m = r.url().match(/^https:\/\/unpkg\.com\/maplibre-gl@[^/]+(\/dist\/.*)$/);
      m ? r.continue({ url: `https://unpkg.com/maplibre-gl@${mlVersion}${m[1]}` }) : r.continue();
    });
  }
  await page.setViewport({ width: nx * 256, height: ny * 256, deviceScaleFactor: 1 });
  page.on('console', m => { if (['error', 'warning'].includes(m.type())) console.error('console.' + m.type() + ':', m.text().slice(0, 300)); });
  page.on('pageerror', e => console.error('pageerror:', e.message));
  page.on('requestfailed', r => console.error('requestfailed:', r.url().slice(0, 120), r.failure()?.errorText));
  page.on('response', r => { if (r.status() >= 400) console.error('http', r.status(), r.url().slice(0, 120)); });
  await page.goto(`${base}/index.html`, { waitUntil: 'domcontentloaded' });
  await page.addStyleTag({ content: '#info,.maplibregl-ctrl{display:none!important}' });
  await page.waitForFunction('window.map || typeof map !== "undefined"', { timeout: 30000 });
  // Layer/paint overrides need the style fully loaded, or setPaintProperty throws
  // for layers that do not exist yet.
  // index.html may stack several map canvases (QGIS group opacity, window.__maps); wait for all.
  await page.waitForFunction('(window.__maps || [map]).every(m => m.isStyleLoaded())', { timeout: 60000 }).catch(async (e) => {
    // A style MapLibre rejects never finishes loading; show why instead of a bare timeout.
    const errors = await page.evaluate(() => window.__mapDiagnostics?.errors || []);
    console.error('style did not load:', [...new Set(errors)].slice(0, 5).join(' | ') || e.message);
    process.exit(1);
  });
  await page.evaluate((lon, lat, zoom, hide, paintOverrides) => {
    for (const m of (window.__maps || [map])) {
      for (const l of m.getStyle().layers) {
        if (hide.some(h => (h.endsWith('*') ? l.id.startsWith(h.slice(0, -1)) : l.id === h))) {
          m.setLayoutProperty(l.id, 'visibility', 'none');
        }
      }
      for (const [id, props] of Object.entries(paintOverrides)) {
        if (!m.getLayer(id)) continue;
        for (const [prop, value] of Object.entries(props)) m.setPaintProperty(id, prop, value);
      }
    }
    map.jumpTo({ center: [lon, lat], zoom, bearing: 0, pitch: 0 });
  }, lon, lat, z + zoomOffset, hide, paintOverrides);
  // Poll from Node (a long in-page promise trips puppeteer's protocol
  // timeout when software GL is slow). Settled = loaded, tiles loaded, and
  // stable for two consecutive polls.
  console.log('maplibre-gl', await page.evaluate(() => (maplibregl.getVersion ? maplibregl.getVersion() : maplibregl.version)));
  const deadline = Date.now() + timeoutSec * 1000;
  let stable = 0;
  let failedPolls = 0;
  while (stable < 2 && failedPolls < 5) {
    if (Date.now() > deadline) {
      const s = await page.evaluate(() => (window.__maps || [map]).map(m => ({ loaded: m.loaded(), tiles: m.areTilesLoaded(), style: m.isStyleLoaded() })));
      console.error('timed out waiting for map to settle', s, await page.evaluate(() => window.__mapDiagnostics));
      process.exit(1);
    }
    await new Promise(r => setTimeout(r, 1000));
    const s = await page.evaluate(() => ({
      ok: (window.__maps || [map]).every(m => m.loaded() && m.areTilesLoaded()),
      styleLoaded: (window.__maps || [map]).every(m => m.isStyleLoaded()),
      errors: (window.__mapDiagnostics?.errors || []).length,
    }));
    stable = s.ok ? stable + 1 : 0;
    // A style MapLibre rejected never finishes loading; stop waiting for it.
    failedPolls = !s.styleLoaded && s.errors > 0 ? failedPolls + 1 : 0;
  }
  const errors = await page.evaluate(() => window.__mapDiagnostics?.errors || []);
  if (errors.length) {
    const unique = [...new Set(errors)];
    console.error(`MapLibre reported ${errors.length} error(s), ${unique.length} distinct:`);
    unique.slice(0, 8).forEach(e => console.error('  ' + e.slice(0, 240)));
  }
  if (!checkOnly) await page.screenshot({ path: OUT });
  await browser.close();
  if (checkOnly) {
    console.log(errors.length ? 'style check FAILED' : 'style check passed: MapLibre loaded the style without errors');
  } else {
    console.log(`wrote ${OUT} (${nx * 256}x${ny * 256}) centre=${lon.toFixed(6)},${lat.toFixed(6)} zoom=${z + zoomOffset}`);
  }
  if (errors.length && !allowErrors) process.exit(1);
})().catch(e => { console.error(e); process.exit(1); });
