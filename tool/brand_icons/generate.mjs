import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const client = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const brand = path.join(client, 'assets', 'brand');
const macAppIcon = path.join(
  client, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset',
);
const macTrayIcon = path.join(
  client, 'macos', 'Runner', 'Assets.xcassets', 'TrayIcon.imageset',
);
const windowsIcons = path.join(client, 'windows', 'runner', 'resources');

async function render(svg, size) {
  return sharp(svg, { density: 600 })
    .resize(size, size, { fit: 'fill' })
    .png({ compressionLevel: 9 })
    .toBuffer();
}

function ico(frames) {
  const directory = Buffer.alloc(6 + frames.length * 16);
  directory.writeUInt16LE(1, 2);
  directory.writeUInt16LE(frames.length, 4);
  let offset = directory.length;
  frames.forEach(({ size, png }, index) => {
    const entry = 6 + index * 16;
    directory.writeUInt8(size === 256 ? 0 : size, entry);
    directory.writeUInt8(size === 256 ? 0 : size, entry + 1);
    directory.writeUInt16LE(1, entry + 4);
    directory.writeUInt16LE(32, entry + 6);
    directory.writeUInt32LE(png.length, entry + 8);
    directory.writeUInt32LE(offset, entry + 12);
    offset += png.length;
  });
  return Buffer.concat([directory, ...frames.map(({ png }) => png)]);
}

const app = await readFile(path.join(brand, 'appicon-light.svg'));
const tray = await readFile(path.join(brand, 'logo-mono-ink.svg'));
await mkdir(macTrayIcon, { recursive: true });

for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
  await writeFile(path.join(macAppIcon, `app_icon_${size}.png`), await render(app, size));
}
for (const [scale, size] of [['1x', 18], ['2x', 36]]) {
  await writeFile(path.join(macTrayIcon, `tray_${scale}.png`), await render(tray, size));
}
await writeFile(path.join(macTrayIcon, 'Contents.json'), `${JSON.stringify({
  images: [
    { filename: 'tray_1x.png', idiom: 'universal', scale: '1x' },
    { filename: 'tray_2x.png', idiom: 'universal', scale: '2x' },
  ],
  info: { author: 'xcode', version: 1 },
}, null, 2)}\n`);

const appFrames = [];
for (const size of [16, 24, 32, 48, 64, 128, 256]) {
  appFrames.push({ size, png: await render(app, size) });
}
const trayFrames = [];
for (const size of [16, 24, 32, 48]) {
  // Windows does not recolor notification icons for dark taskbars.
  trayFrames.push({ size, png: await render(app, size) });
}
await writeFile(path.join(windowsIcons, 'app_icon.ico'), ico(appFrames));
await writeFile(path.join(windowsIcons, 'tray_icon.ico'), ico(trayFrames));
