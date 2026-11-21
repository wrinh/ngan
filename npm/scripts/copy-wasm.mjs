// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const npmDir = resolve(__dirname, '..');
const repoRoot = resolve(npmDir, '..');
const wasmSrc = resolve(repoRoot, '_build/wasm-gc/release/build/web/web.wasm');
const distDir = resolve(npmDir, 'dist');
const wasmDest = resolve(distDir, 'ngan.wasm');

const shouldBuild = process.argv.includes('--build') || !existsSync(wasmSrc);

if (shouldBuild) {
  execFileSync('moon', ['build', '--target', 'wasm-gc', '--release'], {
    cwd: repoRoot,
    stdio: 'inherit',
  });
}

if (!existsSync(wasmSrc)) {
  throw new Error(`Expected built wasm artifact at ${wasmSrc}`);
}

mkdirSync(distDir, { recursive: true });
copyFileSync(wasmSrc, wasmDest);
console.log(`Copied ${wasmSrc} -> ${wasmDest}`);
