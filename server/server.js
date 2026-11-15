// Zdravlje AI server: holds the Claude API key so the phones never do.
// No dependencies (Node 22's built-in http and fetch). Runs in its own
// container on the family server, reachable only through Tailscale.
//
// Nothing a phone sends is saved: no meal text, photos, questions or health
// summaries are logged or written to disk. Only a per-person request count
// and cost estimate for the month are kept, in /data/usage.json.

'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const env = (k, d) => (process.env[k] ?? d);
const API_KEY = env('ANTHROPIC_API_KEY', '');
const PORT = Number(env('PORT', '8787'));
const DATA_DIR = env('DATA_DIR', '/data');
const MODEL_TEXT = env('MODEL_TEXT', 'claude-haiku-5-5');
const MODEL_PHOTO = env('MODEL_PHOTO', 'claude-sonnet-5-5');
const MODEL_ASK = env('MODEL_ASK', 'claude-sonnet-5-5');
const MAX_BODY = 10 * 1024 * 1024;

// "katie:longcode,zoran:othercode" -> code -> person
const PEOPLE = new Map(env('PASSCODES', '').split(',').map(s => s.trim()).filter(Boolean).map(p => {
  const i = p.indexOf(':');
  return [p.slice(i + 1).trim(), p.slice(0, i).trim()];
}).filter(([code, who]) => code.length >= 16 && who));
const ADMINS = new Set(env('ADMINS', '').split(',').map(s => s.trim()).filter(Boolean));

// USD per million tokens. Unknown models are charged at the highest rate here,
// so the estimate errs high and the limit stays safe.
const PRICES = {
  'claude-haiku-5-5': { input: 0.10, output: 0.50 },
  'claude-sonnet-5-5': { input: 2.00, output: 10.00 },
  'claude-opus-5-5': { input: 4.00, output: 20.00 },
};
const priceOf = m => PRICES[m] || { input: 4.00, output: 20.00 };

// ── usage ───────────────────────────────────────────────────────────────────
const usageFile = path.join(DATA_DIR, 'usage.json');
const thisMonth = () => new Date().toISOString().slice(0, 7);
function loadUsage() {
  let u;
  try { u = JSON.parse(fs.readFileSync(usageFile, 'utf8')); } catch { u = {}; }
  if (typeof u.limitUsd !== 'number') u.limitUsd = Number(env('MONTHLY_LIMIT_USD', '10'));
  if (u.month !== thisMonth()) { u.month = thisMonth(); u.costUsd = 0; u.requests = 0; u.byPerson = {}; }
  u.byPerson = u.byPerson || {};
  return u;
}
let usage = loadUsage();
function saveUsage() {
  try {
    fs.writeFileSync(usageFile + '.tmp', JSON.stringify(usage, null, 2));
    fs.renameSync(usageFile + '.tmp', usageFile);
  } catch (e) { console.error('could not save usage:', e.message); }
}
function record(who, model, u) {
  usage = usage.month === thisMonth() ? usage : loadUsage();
  const p = priceOf(model);
  const cost = ((u?.input_tokens || 0) * p.input + (u?.output_tokens || 0) * p.output) / 1e6;
  usage.costUsd = Math.round((usage.costUsd + cost) * 1e6) / 1e6;
  usage.requests += 1;
  const b = usage.byPerson[who] || { requests: 0, costUsd: 0 };
  b.requests += 1;
  b.costUsd = Math.round((b.costUsd + cost) * 1e6) / 1e6;
  usage.byPerson[who] = b;
  saveUsage();
}
const overLimit = () => { usage = usage.month === thisMonth() ? usage : loadUsage(); return usage.costUsd >= usage.limitUsd; };

// ── Claude ──────────────────────────────────────────────────────────────────
const STYLE = 'Write plainly for a non-technical reader. Never use em-dashes; use commas or parentheses instead.';

const MEAL_TOOL = {
  name: 'record_meal',
  description: 'Record the foods in the meal, one entry per distinct food.',
  input_schema: {
    type: 'object',
    properties: {
      items: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            name: { type: 'string', description: 'Short food name as a person would write it, e.g. "Eggs, scrambled".' },
            usda_query: { type: 'string', description: 'Plain search words for the USDA food database, e.g. "egg scrambled".' },
            amount_text: { type: 'string', description: 'Amount in everyday words, e.g. "2 large" or "about 3/4 cup".' },
            grams: { type: 'number', description: 'Best estimate of the edible weight in grams.' },
            calories: { type: 'number' },
            protein_g: { type: 'number' },
            carbs_g: { type: 'number' },
            fat_g: { type: 'number' },
            guess: { type: 'boolean', description: 'True when the amount or the food itself was not stated or visible and you assumed it.' },
            note: { type: 'string', description: 'Very short reason for a guess, e.g. "you did not say how much". Empty if not a guess.' },
          },
          required: ['name', 'usda_query', 'amount_text', 'grams', 'calories', 'protein_g', 'carbs_g', 'fat_g', 'guess'],
        },
      },
      calories_low: { type: 'number', description: 'Low end of a realistic total. Same as the sum for clear descriptions.' },
      calories_high: { type: 'number', description: 'High end of a realistic total.' },
      unclear: { type: 'string', description: 'If the input is not food or cannot be read, say why in one sentence. Otherwise empty.' },
    },
    required: ['items', 'calories_low', 'calories_high'],
  },
};

const MEAL_SYSTEM = `You turn a description or photo of a meal into a list of foods with amounts and nutrition, for a personal food log. Use typical USDA values. Split mixed dishes into their main parts when that helps accuracy (e.g. salmon, rice, oil). Include cooking fats and sauces only when stated or clearly visible, and mark them as guesses when you assume the amount. Keep names short. ${STYLE}`;

async function claude(body) {
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(90_000),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const err = new Error(j?.error?.message || `Claude API ${r.status}`);
    err.status = r.status === 429 || r.status === 529 ? 503 : 502;
    throw err;
  }
  return j;
}

async function meal(who, { text, image, mediaType, note, avoid }) {
  const content = [];
  let model = MODEL_TEXT;
  if (image) {
    if (!/^image\/(jpeg|png|webp|heic)$/.test(mediaType || '')) throw Object.assign(new Error('Unsupported photo type'), { status: 400 });
    content.push({ type: 'image', source: { type: 'base64', media_type: mediaType, data: image } });
    model = MODEL_PHOTO;
  }
  let prompt = image ? 'Here is a photo of a meal.' : `The meal: ${String(text || '').slice(0, 2000)}`;
  if (note) prompt += `\nThe person adds: ${String(note).slice(0, 500)}`;
  if (Array.isArray(avoid) && avoid.length) prompt += `\nFoods they avoid (just name them if present): ${avoid.slice(0, 40).join(', ')}`;
  content.push({ type: 'text', text: prompt });
  const j = await claude({
    model, max_tokens: 1500, system: MEAL_SYSTEM,
    tools: [MEAL_TOOL], tool_choice: { type: 'tool', name: 'record_meal' },
    messages: [{ role: 'user', content }],
  });
  record(who, model, j.usage);
  const out = j.content?.find(c => c.type === 'tool_use')?.input;
  if (!out) throw Object.assign(new Error('No result from Claude'), { status: 502 });
  return out;
}

const ASK_SYSTEM = `You help one person understand their own data from a personal health tracker app (sleep, recovery, heart rate, HRV, activity, meals, water). You get their question and daily summaries as JSON. Answer from those numbers: be specific, quote the relevant figures, say how many days the answer rests on, and say plainly when the sample is small or another factor could explain a pattern. If the data cannot answer the question, say what is missing. Keep it short: a few sentences, plus a small table only when comparing groups. This is general information, not medical advice; if something looks like a health concern, suggest they talk to a doctor. ${STYLE}`;

async function ask(who, { question, context, history }) {
  const messages = [];
  for (const h of (Array.isArray(history) ? history.slice(-6) : [])) {
    if ((h.role === 'user' || h.role === 'assistant') && typeof h.text === 'string') messages.push({ role: h.role, content: h.text.slice(0, 4000) });
  }
  const ctx = JSON.stringify(context ?? {}).slice(0, 120_000);
  messages.push({ role: 'user', content: `My data:\n${ctx}\n\nMy question: ${String(question || '').slice(0, 1000)}` });
  const j = await claude({ model: MODEL_ASK, max_tokens: 1200, system: ASK_SYSTEM, messages });
  record(who, MODEL_ASK, j.usage);
  return { answer: (j.content || []).filter(c => c.type === 'text').map(c => c.text).join('\n').trim() };
}

// ── HTTP ────────────────────────────────────────────────────────────────────
function send(res, status, obj) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', c => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('Too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
      catch { reject(Object.assign(new Error('Bad JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true });
    const code = (req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
    const who = PEOPLE.get(code);
    if (!who) return send(res, 401, { error: 'Pass code not accepted.' });

    if (req.method === 'GET' && url.pathname === '/v1/status') {
      usage = usage.month === thisMonth() ? usage : loadUsage();
      return send(res, 200, {
        person: who, admin: ADMINS.has(who), month: usage.month, requests: usage.requests,
        costUsd: usage.costUsd, limitUsd: usage.limitUsd, mine: usage.byPerson[who] || { requests: 0, costUsd: 0 },
        keySet: Boolean(API_KEY),
      });
    }
    if (req.method === 'POST' && url.pathname === '/v1/limit') {
      if (!ADMINS.has(who)) return send(res, 403, { error: 'Only an admin can change the limit.' });
      const b = await readBody(req);
      const v = Number(b.limitUsd);
      if (!(v >= 1 && v <= 200)) return send(res, 400, { error: 'Limit must be between $1 and $200.' });
      usage.limitUsd = v;
      saveUsage();
      return send(res, 200, { limitUsd: v });
    }
    if (req.method === 'POST' && (url.pathname === '/v1/meal' || url.pathname === '/v1/ask')) {
      if (!API_KEY) return send(res, 503, { error: 'The server has no Claude key yet.' });
      if (overLimit()) return send(res, 429, { error: 'This month\'s AI limit has been reached.' });
      const b = await readBody(req);
      return send(res, 200, url.pathname === '/v1/meal' ? await meal(who, b) : await ask(who, b));
    }
    send(res, 404, { error: 'Not found' });
  } catch (e) {
    console.error(new Date().toISOString(), url.pathname, e.message);
    send(res, e.status || 500, { error: e.status ? e.message : 'Server error' });
  }
});

if (require.main === module) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  server.listen(PORT, '0.0.0.0', () => console.log(`Zdravlje AI server on ${PORT}; ${PEOPLE.size} pass code(s); limit $${usage.limitUsd}/month`));
}
module.exports = { server, priceOf, PEOPLE };
