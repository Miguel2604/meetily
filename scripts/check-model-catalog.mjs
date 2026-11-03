#!/usr/bin/env node
// Reports drift between Meetily's built-in model catalogs and upstream Hugging Face.
// Prints a markdown report; exits 1 when there is something to act on, 0 when clean.
// Usage: node scripts/check-model-catalog.mjs [--days 8]
import { readFileSync } from 'node:fs';

const ROOT = new URL('../frontend/src-tauri/src/', import.meta.url);
const read = (path) => readFileSync(new URL(path, ROOT), 'utf8');
const daysArg = process.argv.indexOf('--days');
const DAYS = daysArg > -1 ? Number(process.argv[daysArg + 1]) : 8;
const since = Date.now() - DAYS * 24 * 60 * 60 * 1000;

// Upstream whisper.cpp files deliberately left out of the picker.
const WHISPER_SKIP = [
  /\.en[.-]/, // English-only variants: the app is multilingual
  /large-v[12]/, // superseded by large-v3
];

// Hugging Face authors whose new speech-recognition repos are worth a look.
const WATCHED_AUTHORS = ['nvidia', 'istupakov', 'moondream', 'FermionResearch', 'openai', 'ggerganov'];

async function hf(path) {
  const response = await fetch(`https://huggingface.co/api/${path}`);
  if (!response.ok) throw new Error(`HF ${path}: ${response.status}`);
  return response.json();
}

async function urlStatus(url) {
  try {
    const response = await fetch(url, { method: 'HEAD', redirect: 'follow' });
    return response.status;
  } catch (error) {
    return error.message;
  }
}

const sections = [];

// 1. New whisper.cpp ggml files upstream.
const whisperCatalog = read('config.rs');
const catalogFiles = new Set([...whisperCatalog.matchAll(/"(ggml-[^"]+\.bin)"/g)].map((m) => m[1]));
const upstream = await hf('models/ggerganov/whisper.cpp');
const newWhisper = upstream.siblings
  .map((s) => s.rfilename)
  .filter((f) => /^ggml-.*\.bin$/.test(f) && !catalogFiles.has(f) && !WHISPER_SKIP.some((re) => re.test(f)));
if (newWhisper.length) {
  sections.push(
    `### New whisper.cpp models\nAdd to \`WHISPER_MODEL_CATALOG\` in \`config.rs\`:\n${newWhisper.map((f) => `- \`${f}\``).join('\n')}`,
  );
}

// 2. Every pinned download URL still resolves.
const parakeet = read('parakeet_engine/parakeet_engine.rs');
const builtin = read('summary/summary_engine/models.rs');
const urls = [];
for (const [, base, artifacts] of parakeet.matchAll(
  /source_base_url: "(https:[^"]+)",\s*artifacts: (\w+),/g,
)) {
  const block = parakeet.match(new RegExp(`const ${artifacts}: &\\[ArtifactSpec\\] = &\\[([\\s\\S]*?)\\n\\];`))[1];
  for (const entry of block.matchAll(/filename: "([^"]+)"[^}]*?source_url: (None|Some\("([^"]+)"\))/g)) {
    urls.push(entry[3] ?? `${base}/${entry[1]}`);
  }
}
for (const file of catalogFiles) urls.push(`https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${file}`);
for (const [, url] of builtin.matchAll(/download_url: "(https:[^"]+)"/g)) urls.push(url);
const broken = [];
for (const url of urls) {
  const status = await urlStatus(url);
  if (status !== 200) broken.push(`- ${status}: ${url}`);
}
if (broken.length) sections.push(`### Broken download URLs\n${broken.join('\n')}`);

// 3. New speech-recognition repos from watched authors.
const fresh = [];
for (const author of WATCHED_AUTHORS) {
  const models = await hf(`models?author=${author}&pipeline_tag=automatic-speech-recognition&sort=createdAt&limit=20`);
  for (const model of models) {
    if (Date.parse(model.createdAt) >= since) fresh.push(`- [${model.id}](https://huggingface.co/${model.id}) (${model.createdAt.slice(0, 10)})`);
  }
}
if (fresh.length) {
  sections.push(
    `### New speech models in the last ${DAYS} days\nCheck the architecture first: the Parakeet engine runs NeMo TDT ONNX exports (encoder-model, decoder_joint-model, nemo128, vocab.txt). Validate a candidate with \`PARAKEET_SMOKE_DIR=... PARAKEET_SMOKE_F32=... cargo test --lib parakeet_model_smoke -- --ignored --nocapture\`.\n${fresh.join('\n')}`,
  );
}

console.log(sections.length ? `## Model catalog drift\n\n${sections.join('\n\n')}` : 'Model catalogs are up to date.');
process.exit(sections.length ? 1 : 0);
