// 483 embed builder: link buttons on webhook posts (webhook_send_v2) and posting as a webhook from the app
// (webhook_post_member). Starts like stage24w (stage 24 + stand-ins + 155), runs 483, then all of 24w's webhook_send
// checks again (webhook_send now goes through webhook_post), then the new functions.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { prepare, checks } from './stage24w.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const base = 24;

const link = (label, url = 'https://yapin.gg/rules', extra = {}) => ({ type: 'button', style: 'link', label, url, ...extra });

export default async function (h) {
  await prepare(h);
  const MIGRATION = readFileSync(join(here, '..', '..', 'supabase', 'migrations', '483_embed_builder.sql'), 'utf8').replace(/\r\n/g, '\n');
  await h.db.exec(MIGRATION);
  await h.ok('483 re-runs cleanly', () => h.db.exec(MIGRATION));
  await checks(h);

  const service = async () => { await h.db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false); set role service_role;`); };
  const err = async (sql, params = []) => { try { await h.db.query(sql, params); return null; } catch (e) { return e; } };
  const clearRate = async () => { await h.admin(); await h.q(`delete from webhook_rate`); await service(); };
  const v2 = (id, tok, body, embeds, comps) => `select * from webhook_send_v2('${id}', '${tok}', ${body === null ? 'null' : `'${body}'`}, null, null, ${embeds ? `'${JSON.stringify(embeds)}'::jsonb` : 'null'}, null, ${comps ? `'${JSON.stringify(comps)}'::jsonb` : 'null'})`;
  const member = (uid, id, body, embeds, comps) => h.db.query(`select * from webhook_post_member($1, $2, $3, $4::jsonb, $5::jsonb)`,
    [uid, id, body, embeds ? JSON.stringify(embeds) : null, comps ? JSON.stringify(comps) : null]);

  await h.admin();
  h.eq('flag row is test-only', await h.one(`select mode from feature_flags where key = 'embed_builder'`), { mode: 'test' });
  const owner = await h.signup('autumn@test.dev', 'autumn');
  const helper = await h.signup('helper@test.dev', 'helper');
  const nobody = await h.signup('nobody@test.dev', 'nobody');
  await h.as(owner);
  const sid = (await h.one(`select create_server('Rules', null) id`)).id;
  const ch = (await h.one(`select id from channels where server_id=$1 and kind='text' limit 1`, [sid])).id;
  await h.admin();
  const role = (await h.one(`insert into roles (server_id, name, position, manage_server, manage_messages, perms) values ($1, 'Hooks', 1, false, false, '{"manage_webhooks": true}') returning id`, [sid])).id;
  await h.q(`insert into server_members (server_id, user_id) values ($1, $2), ($1, $3) on conflict do nothing`, [sid, helper, nobody]);
  await h.q(`insert into member_roles (server_id, user_id, role_id) values ($1, $2, $3)`, [sid, helper, role]);
  await h.q(`update feature_flags set servers = servers || array[$1::uuid] where key = 'webhooks'`, [sid]);
  await h.as(owner);
  const hook = (await h.one(`select webhook_create($1, 'Rules bot') w`, [ch])).w;

  // ---- nobody outside the API can call the new functions ----
  for (const who of [owner, null]) {
    await h.as(who);
    await h.fails(`${who ? 'signed in' : 'anon'}: no webhook_send_v2`, v2(hook.id, hook.token, 'hi', null, null));
    await h.fails(`${who ? 'signed in' : 'anon'}: no webhook_post_member`, `select webhook_post_member('${owner}', '${hook.id}', 'hi')`);
    await h.fails(`${who ? 'signed in' : 'anon'}: no webhook_take_member`, `select webhook_take_member('${owner}', '${hook.id}')`);
    await h.fails(`${who ? 'signed in' : 'anon'}: no webhook_post`, `select webhook_post(w, 'hi', null, null, null, null, null) from webhooks w`);
  }
  await service();
  await h.fails('service role: no webhook_post either (token check skipped)', `select webhook_post(w, 'hi', null, null, null, null, null) from webhooks w`);
  await h.fails('service role: no webhook_member_guard', `select webhook_member_guard('${owner}', '${hook.id}')`);
  await h.fails('service role: no webhook_by_token', `select webhook_by_token('${hook.id}', '${hook.token}')`);

  // ---- link buttons through the URL ----
  const rows = [{ type: 'row', components: [link('Rules'), link('', 'https://yapin.gg/tos', { emoji: '📜' })] }];
  h.eq('flag off: buttons refused', (await err(v2(hook.id, hook.token, 'hi', null, rows)))?.hint, 'webhook:50035');
  h.eq('flag off: v2 without buttons still posts', (await h.one(v2(hook.id, hook.token, 'plain', null, null))).content, 'plain');
  await h.admin();
  await h.q(`update feature_flags set servers = array[$1::uuid] where key = 'embed_builder'`, [sid]);
  await clearRate();
  const m1 = await h.one(v2(hook.id, hook.token, null, [{ title: 'Server rules', color: 15548997 }], rows));
  h.eq('buttons stored', m1.components[0].components.map((b) => [b.style, b.label, b.url, b.emoji ?? null]),
    [['link', 'Rules', 'https://yapin.gg/rules', null], ['link', '', 'https://yapin.gg/tos', '📜']]);
  h.eq('embeds stored', m1.embeds[0].title, 'Server rules');
  h.eq('empty button list dropped', (await h.one(v2(hook.id, hook.token, 'x', null, []))).components, null);
  h.eq('wrong token still refused', (await err(v2(hook.id, 'f'.repeat(64), 'x', null, rows)))?.hint, 'webhook:50027');
  await clearRate();
  const bad = {
    'a custom_id button': [{ type: 'row', components: [{ type: 'button', style: 'primary', label: 'Press', custom_id: 'x' }] }],
    'a link with a custom_id': [{ type: 'row', components: [link('A', 'https://a.dev', { custom_id: 'x' })] }],
    'an http link': [{ type: 'row', components: [link('A', 'http://a.dev')] }],
    'a javascript link': [{ type: 'row', components: [link('A', 'javascript:alert(1)')] }],
    'no label or emoji': [{ type: 'row', components: [link('')] }],
    'six in a row': [{ type: 'row', components: Array.from({ length: 6 }, (_, i) => link(`B${i}`)) }],
    'six rows': Array.from({ length: 6 }, () => ({ type: 'row', components: [link('B')] })),
    'an empty row': [{ type: 'row', components: [] }],
    'a V2 layout': [{ type: 17, components: [{ type: 10, content: 'hi' }] }],
    'not an array': { type: 'row' },
    'a long label': [{ type: 'row', components: [link('x'.repeat(81))] }],
  };
  for (const [what, comps] of Object.entries(bad)) {
    h.eq(`refused: ${what}`, (await err(v2(hook.id, hook.token, 'x', null, comps)))?.hint, 'webhook:50035');
  }
  h.eq('buttons need text or embeds next to them', (await err(v2(hook.id, hook.token, '', null, rows)))?.hint, 'webhook:50006');
  h.eq('slur in a button label refused', (await err(v2(hook.id, hook.token, 'x', null, [{ type: 'row', components: [link('retard')] }])))?.hint, 'webhook:200000');
  h.eq('adult link in a button refused', (await err(v2(hook.id, hook.token, 'x', null, [{ type: 'row', components: [link('A', 'https://pornhub.com/x')] }])))?.hint, 'webhook:200000');

  // ---- posting from the app ----
  await clearRate();
  const p1 = (await member(helper, hook.id, '', [{ title: 'FAQ', description: '**Q:** hi' }], rows)).rows[0];
  h.eq('Manage Webhooks: posts as the webhook', { name: p1.webhook.name, id: p1.webhook.id, buttons: p1.components.length }, { name: 'Rules bot', id: hook.id, buttons: 1 });
  h.eq('nobody: refused', (await err(`select webhook_post_member($1, $2, 'hi')`, [nobody, hook.id]))?.hint, 'webhook:50001');
  h.eq('unknown webhook', (await err(`select webhook_post_member($1, gen_random_uuid(), 'hi')`, [owner]))?.hint, 'webhook:10015');
  h.eq('no @everyone from the app', (await member(owner, hook.id, 'hey @everyone')).rows[0].content, 'hey @​everyone');
  await clearRate();
  const take = async (uid) => (await h.one(`select webhook_take_member($1, $2) t`, [uid, hook.id])).t;
  for (let i = 0; i < 5; i++) h.eq(`take ${i} ok`, await take(owner), { ok: true });
  h.eq('rate limit applies', (await take(owner)).code, 429);
  h.eq('nobody: take refused', (await err(`select webhook_take_member($1, $2)`, [nobody, hook.id]))?.hint, 'webhook:50001');
  // A lock: the helper (Manage Webhooks, no Manage Messages) can't post even through the owner's webhook.
  await clearRate();
  await h.admin();
  await h.q(`update servers set locked_until = now() + interval '1 hour' where id = $1`, [sid]);
  await service();
  h.eq('locked: Manage Webhooks alone is refused', (await err(`select webhook_post_member($1, $2, 'hi')`, [helper, hook.id]))?.hint, 'webhook:50001');
  h.eq('locked: take refused too', (await err(`select webhook_take_member($1, $2)`, [helper, hook.id]))?.hint, 'webhook:50001');
  h.eq('locked: the owner still posts', (await member(owner, hook.id, 'lock note')).rows[0].content, 'lock note');
  await h.admin();
  await h.q(`update servers set locked_until = null where id = $1`, [sid]);
  await clearRate();
  const longEmoji = `<a:${'x'.repeat(32)}:11111111-2222-4333-8444-555555555555>`;
  h.eq('a long custom emoji fits on a button', (await member(owner, hook.id, 'e', null, [{ type: 'row', components: [link('', 'https://a.dev', { emoji: longEmoji })] }])).rows[0].components[0].components[0].emoji, longEmoji);
  await clearRate();
  await h.admin();
  await h.q(`delete from member_roles where user_id = $1`, [helper]);
  await service();
  h.eq('lost Manage Webhooks: refused', (await err(`select webhook_post_member($1, $2, 'hi')`, [helper, hook.id]))?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`update feature_flags set servers = '{}' where key = 'embed_builder'`);
  await service();
  h.eq('flag off: no posting from the app', (await err(`select webhook_post_member($1, $2, 'hi')`, [owner, hook.id]))?.hint, 'webhook:50001');
  await h.admin();
  await h.q(`update feature_flags set users = array[$1::uuid] where key = 'embed_builder'`, [owner]);
  await service();
  h.eq('flag test user: posting from the app works anywhere', (await member(owner, hook.id, 'test user')).rows[0].content, 'test user');
  await h.admin();
}
