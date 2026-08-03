import { pipeline } from "@xenova/transformers";

let _pipe = null;

/**
 * Loads the feature-extraction pipeline for Xenova/all-MiniLM-L6-v2.
 * Safe to call multiple times — no-op if already loaded.
 */
export async function warmUp() {
  if (_pipe) return;
  const t = Date.now();
  _pipe = await pipeline("feature-extraction", "Xenova/all-MiniLM-L6-v2");
  process.stderr.write(`[jenga-router] Model warmed up in ${Date.now() - t}ms\n`);
}

/**
 * Embeds text using the loaded pipeline.
 * Returns a Float32Array of length 384.
 */
export async function embed(text) {
  const output = await _pipe(text, { pooling: "mean", normalize: true });
  return output.data;
}
