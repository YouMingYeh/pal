// Samples the supplied MIT Bloub SVG engine; generation needs Node and rsvg-convert.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';

const ios = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(resolve(ios, 'Pal/Mascot/Cloud.html'), 'utf8');
const sourceHash = '12a1bac5b8e7326a8f680d142936281719c708999500f5c89226ac81ac8e57af';
assert.equal(createHash('sha256').update(source).digest('hex'), sourceHash, 'Review the supplied engine before changing its sampling adapter.');
const emotions = ['fier', 'heureux', 'hilare', 'curieux', 'confus', 'surpris', 'timide', 'triste', 'colere', 'somnolent', 'attentif', 'neutre'];
const frameCount = 32, duration = 4, pixels = 128;
const svg = { innerHTML: '', setAttribute() {} };
const context = vm.createContext({
  window: {}, document: { querySelector: () => svg, addEventListener() {}, hidden: false },
  requestAnimationFrame: () => 1, cancelAnimationFrame() {},
});
const script = source.match(/<script>([\s\S]*?)<\/script>/)?.[1];
assert.ok(script);
// Only the generation VM exports sampling; the shipped HTML remains untouched.
const injection = `window.sampleMascot = (expression, time) => {
  const frame = new BotEngine(RAYON, 'idle', cloud, EXPRESSION_BY_ID.get(expression)).sample(time);
  draw(frame);
  return { svg: svg.innerHTML, eyes: frame.eyes.map(eye => eye.d + eye.matrix).join('|'), body: frame.bodyPath };
};\nwindow.blinkLidForGeneration = require('bot/face.ts').liveliness;\n`;
vm.runInContext(script.replace('window.Mascot = {', injection + 'window.Mascot = {'), context, { timeout: 30000 });
assert.ok(context.window.sampleMascot);
assert.ok(context.window.blinkLidForGeneration(1.5).lid < 0.25, 'The sampled cycle must contain an actual eye blink.');

for (const emotion of emotions) {
  const eyeStates = new Set(), bodyStates = new Set(), pixelStates = new Set();
  for (let index = 0; index < frameCount; index++) {
    const frame = context.window.sampleMascot(emotion, index * duration / frameCount);
    assert.ok(frame.svg.includes('#ff7a1a') && frame.svg.includes('#fffff5'));
    assert.ok(!frame.svg.includes('#3b82f6'), 'No notification dot belongs in a chat avatar.');
    eyeStates.add(frame.eyes); bodyStates.add(frame.body);
    const xml = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-158 -158 316 316">${frame.svg}</svg>`;
    const raster = spawnSync('rsvg-convert', ['--width', String(pixels), '--height', String(pixels)], { input: xml });
    assert.equal(raster.status, 0, raster.stderr?.toString());
    assert.equal(raster.stdout.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
    assert.equal(raster.stdout.readUInt32BE(16), pixels);
    assert.equal(raster.stdout.readUInt32BE(20), pixels);
    pixelStates.add(createHash('sha256').update(raster.stdout).digest('hex'));
    const asset = resolve(ios, `Pal/Assets.xcassets/PalMascotMotion-${emotion}-${index}.imageset`);
    mkdirSync(asset, { recursive: true });
    writeFileSync(resolve(asset, 'mascot.png'), raster.stdout);
    writeFileSync(resolve(asset, 'Contents.json'), JSON.stringify({ images: [{ filename: 'mascot.png', idiom: 'universal' }], info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
  }
  assert.equal(pixelStates.size, frameCount, 'Every generated frame must preserve real motion.');
  assert.ok(eyeStates.size > 1 && bodyStates.size > 1, 'Eyes and breathing must both animate.');
  console.log(`${emotion}: ${frameCount} distinct ${pixels}px frames, ${duration}s, source ${sourceHash}`);
}
