// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import type { NganInitOptions, NganWasmExports, WasmSource } from './types.js';

type CompileWithBuiltins = (
  bytes: BufferSource,
  options?: { builtins?: string[] },
) => Promise<WebAssembly.Module>;

function isBufferSource(v: unknown): v is BufferSource {
  return v instanceof ArrayBuffer || ArrayBuffer.isView(v);
}

function isResponse(v: unknown): v is Response {
  return typeof Response !== 'undefined' && v instanceof Response;
}

function isNodeRuntime(): boolean {
  const g = globalThis as unknown as {
    process?: { versions?: { node?: string } };
  };
  return typeof g.process?.versions?.node === 'string';
}

async function readNodeFileBytes(pathOrUrl: string | URL): Promise<ArrayBuffer> {
  const spec = 'node:' + 'fs/promises';
  const fs = (await import(/* @vite-ignore */ spec)) as {
    readFile(p: string | URL): Promise<Uint8Array>;
  };
  const data = await fs.readFile(pathOrUrl);
  const copy = new Uint8Array(data.byteLength);
  copy.set(data);
  return copy.buffer;
}

export async function resolveWasmBytes(source?: WasmSource): Promise<BufferSource> {
  if (source === undefined) {
    const defaultUrl = new URL('./ngan.wasm', import.meta.url);
    if (defaultUrl.protocol === 'file:') {
      return readNodeFileBytes(defaultUrl);
    }
    const resp = await fetch(defaultUrl);
    if (!resp.ok) {
      throw new Error(
        `Failed to fetch ngan.wasm from ${defaultUrl.href}: ${resp.status} ${resp.statusText}`,
      );
    }
    return resp.arrayBuffer();
  }

  if (isBufferSource(source)) {
    return source;
  }

  if (isResponse(source)) {
    if (!source.ok) {
      throw new Error(
        `Failed to load ngan.wasm Response: ${source.status} ${source.statusText}`,
      );
    }
    return source.arrayBuffer();
  }

  if (source instanceof URL) {
    if (source.protocol === 'file:') {
      return readNodeFileBytes(source);
    }
    const resp = await fetch(source);
    if (!resp.ok) {
      throw new Error(
        `Failed to fetch ngan.wasm from ${source.href}: ${resp.status} ${resp.statusText}`,
      );
    }
    return resp.arrayBuffer();
  }

  if (typeof source === 'string') {
    if (source.startsWith('file://')) {
      return readNodeFileBytes(new URL(source));
    }
    const isHttpOrBrowserUrl =
      source.startsWith('http://') ||
      source.startsWith('https://') ||
      source.startsWith('blob:') ||
      source.startsWith('data:');
    if (!isHttpOrBrowserUrl && typeof fetch === 'undefined') {
      return readNodeFileBytes(source);
    }
    if (isNodeRuntime() && !isHttpOrBrowserUrl) {
      try {
        return await readNodeFileBytes(source);
      } catch {
        // Fall through to URL/fetch if not a direct filesystem path
      }
    }
    const resp = await fetch(source);
    if (!resp.ok) {
      throw new Error(
        `Failed to fetch ngan.wasm from ${source}: ${resp.status} ${resp.statusText}`,
      );
    }
    return resp.arrayBuffer();
  }

  throw new TypeError('Unsupported wasmSource provided to loadNganWasm');
}

/**
 * Compile and instantiate the `ngan` WebAssembly GC module using the
 * `wasm:js-string` builtins and MoonBit string literal global imports.
 */
export async function loadNganWasm(
  options: NganInitOptions = {},
): Promise<NganWasmExports> {
  const { wasmSource } = options;
  let mod: WebAssembly.Module;

  if (wasmSource instanceof WebAssembly.Module) {
    mod = wasmSource;
  } else {
    const bytes = await resolveWasmBytes(wasmSource);
    const compileFn = WebAssembly.compile as unknown as CompileWithBuiltins;
    try {
      mod = await compileFn(bytes, { builtins: ['js-string'] });
    } catch (err) {
      throw new Error(
        'Failed to compile ngan WebAssembly GC module (requires WasmGC + js-string builtins: Chrome 130+, Firefox 134+, Safari 18.4+, or Node 22+): ' +
          String(err),
      );
    }
  }

  const stringGlobals: Record<string, string> = {};
  for (const im of WebAssembly.Module.imports(mod)) {
    if (im.module === '_' && im.kind === 'global') {
      stringGlobals[im.name] = im.name;
    }
  }

  const instance = await WebAssembly.instantiate(
    mod,
    { _: stringGlobals } as unknown as WebAssembly.Imports,
  );
  return instance.exports as NganWasmExports;
}
