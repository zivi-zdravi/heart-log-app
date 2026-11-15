// node test.js — runs the server against a stubbed Claude API.
'use strict';
const assert = require('assert');
const os = require('os'), fs = require('fs'), path = require('path');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zai-'));
Object.assign(process.env, { DATA_DIR: dir, ANTHROPIC_API_KEY: 'test', PASSCODES: 'katie:0123456789abcdef0123,zoran:short', ADMINS: 'katie', MONTHLY_LIMIT_USD: '1' });
const realFetch = global.fetch;
let lastBody;
global.fetch = async (url, opts) => {
  if (String(url).startsWith('https://api.anthropic.com')) {
    lastBody = JSON.parse(opts.body);
    const isAsk = !lastBody.tools;
    return new Response(JSON.stringify(isAsk
      ? { content: [{ type: 'text', text: 'You slept 7 h.' }], usage: { input_tokens: 1000, output_tokens: 100 } }
      : { content: [{ type: 'tool_use', name: 'record_meal', input: { items: [{ name: 'Egg', usda_query: 'egg', amount_text: '1 large', grams: 50, calories: 72, protein_g: 6, carbs_g: 0.4, fat_g: 5, guess: false }], calories_low: 72, calories_high: 72 } }], usage: { input_tokens: 2_000_000, output_tokens: 1000 } }), { status: 200 });
  }
  return realFetch(url, opts);
};
const { server } = require('./server.js');
server.listen(0, async () => {
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = (p, { code, body, method } = {}) => realFetch(base + p, { method: method || (body ? 'POST' : 'GET'), headers: code ? { authorization: `Bearer ${code}` } : {}, body: body && JSON.stringify(body) });
  const K = '0123456789abcdef0123';
  assert.equal((await call('/health')).status, 200);
  assert.equal((await call('/v1/status')).status, 401, 'no code');
  assert.equal((await call('/v1/status', { code: 'short' })).status, 401, 'short codes are refused');
  let s = await (await call('/v1/status', { code: K })).json();
  assert.equal(s.person, 'katie'); assert.equal(s.admin, true); assert.equal(s.limitUsd, 1);
  let r = await call('/v1/meal', { code: K, body: { text: 'an egg', avoid: ['peanuts'] } });
  assert.equal(r.status, 200);
  const m = await r.json();
  assert.equal(m.items[0].name, 'Egg');
  assert.equal(lastBody.model, 'claude-haiku-5-5');
  assert.ok(lastBody.messages[0].content.at(-1).text.includes('peanuts'));
  s = await (await call('/v1/status', { code: K })).json();
  assert.ok(Math.abs(s.costUsd - 0.2005) < 1e-9, 'cost ' + s.costUsd);
  r = await call('/v1/meal', { code: K, body: { image: 'AAAA', mediaType: 'image/gif' } });
  assert.equal(r.status, 400, 'odd photo type refused');
  r = await call('/v1/ask', { code: K, body: { question: 'how did I sleep', context: { days: [] } } });
  assert.equal((await r.json()).answer, 'You slept 7 h.');
  assert.equal(lastBody.model, 'claude-sonnet-5-5');
  // Over the limit after enough meals
  for (let i = 0; i < 4; i++) await call('/v1/meal', { code: K, body: { text: 'egg' } });
  r = await call('/v1/meal', { code: K, body: { text: 'egg' } });
  assert.equal(r.status, 429);
  assert.equal((await call('/v1/limit', { code: K, body: { limitUsd: 5 } })).status, 200);
  assert.equal((await call('/v1/meal', { code: K, body: { text: 'egg' } })).status, 200);
  assert.equal((await call('/v1/limit', { code: K, body: { limitUsd: 5000 } })).status, 400);
  const saved = JSON.parse(fs.readFileSync(path.join(dir, 'usage.json'), 'utf8'));
  assert.equal(saved.limitUsd, 5);
  assert.ok(!JSON.stringify(saved).includes('egg'), 'no meal text on disk');
  console.log('all server tests passed');
  server.close();
});
