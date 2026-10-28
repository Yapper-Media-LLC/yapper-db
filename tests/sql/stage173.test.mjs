// 173: slowmode lets a picture album (picture-only messages right after an accepted one) through.
// The stand-ins stop early, so: 001..024 plus small stand-ins for what 142's version of message_slowmode reads.
export const base = 24;
export const extra = ['031_feature_flags_batch1.sql'];

const STUBS = `
alter table public.channels add column if not exists category_id uuid;
alter table public.channels add column if not exists auto_slow_until timestamptz;
alter table public.messages add column if not exists reply_to_id uuid;
alter table public.messages add column if not exists voice_secs real;
create table if not exists public.post_marks (channel_id uuid, author_id uuid, kind text, at timestamptz, primary key (channel_id, author_id, kind));
create table if not exists public.channel_overrides (channel_id uuid, category_id uuid);
create or replace function public.channel_perm(cid uuid, perm text) returns boolean language sql as $$ select false $$;
create or replace function public.server_locked(sid uuid) returns boolean language sql as $$ select false $$;
`;

export default async function (h) {
  await h.db.exec(STUBS);
  const fs = await import('node:fs');
  const sql = fs.readFileSync(new URL('../../supabase/migrations/173_slowmode_albums.sql', import.meta.url), 'utf8');
  await h.db.exec(sql);
  await h.db.exec(sql); // re-runnable

  const owner = await h.signup('own@test.dev', 'owner');
  const pleb = await h.signup('pleb@test.dev', 'pleb');
  await h.as(owner);
  const sid = (await h.one(`select create_server('Slow', null) id`)).id;
  const gen = (await h.one(`select id from channels where server_id=$1 and name='general'`, [sid])).id;
  await h.q(`insert into invites (code, server_id, created_by) values ('slow1234', $1, $2)`, [sid, owner]);
  await h.q(`select set_channel_posting($1, false, null, 300)`, [gen]);
  await h.as(pleb); await h.q(`select join_server('slow1234')`);
  await h.admin(); await h.q(`update profiles set created_at = now() - interval '2 days' where id = $1`, [pleb]); await h.as(pleb);

  const pic = (n, ext = 'png') => `${pleb}/pic${n}.${ext}`;
  const ins = (path, extra = '') => h.q(`insert into messages (channel_id, author_id, content, attachment_path${extra ? ', voice_secs' : ''}) values ($1,$2,'',$3${extra ? ', 3' : ''})`, [gen, pleb, path]);
  const insSql = `insert into messages (channel_id, author_id, content, attachment_path) values ($1,$2,'',$3)`;
  await h.q(`insert into messages (channel_id, author_id, content, attachment_path) values ($1,$2,'look',$3)`, [gen, pleb, pic(0)]);
  await h.fails('a file (not a picture) is not part of an album', insSql, [gen, pleb, `${pleb}/notes.zip`]);
  await h.fails('a voice message is not part of an album', `insert into messages (channel_id, author_id, content, attachment_path, voice_secs) values ($1,$2,'',$3,3)`, [gen, pleb, `${pleb}/v.ogg`]);
  for (let i = 1; i <= 9; i++) {
    await h.ok(`album picture ${i + 1} goes through`, () => ins(pic(i, i % 2 ? 'webp' : 'gif')));
  }
  await h.fails('an 11th picture is refused', insSql, [gen, pleb, pic(10)]);
  await h.fails('text is still refused', `insert into messages (channel_id, author_id, content) values ($1,$2,'two')`, [gen, pleb]);
  h.eq('ten messages in', (await h.q(`select id from messages where author_id=$1 and channel_id=$2`, [pleb, gen])).length, 10);

  // Deleting the extras doesn't make room for more.
  await h.q(`delete from messages where author_id = $1 and content = ''`, [pleb]);
  await h.fails('after deleting the album, more pictures are still refused', insSql, [gen, pleb, pic(20)]);
  h.eq('album counter kept', (await h.one(`select album_n from post_marks where author_id = $1`, [pleb])).album_n, 9);

  // Outside the 15 second window a picture is a normal message (refused while slowmode runs).
  await h.admin();
  await h.q(`update post_marks set at = now() - interval '20 seconds', album_n = 0 where author_id = $1`, [pleb]);
  await h.as(pleb);
  await h.fails('a late picture waits for slowmode', insSql, [gen, pleb, pic(11)]);

  // Once slowmode is over, a new accepted message resets the counter.
  await h.admin();
  await h.q(`update post_marks set at = now() - interval '10 minutes', album_n = 9 where author_id = $1`, [pleb]);
  await h.q(`delete from messages where author_id = $1`, [pleb]); // (created_at can't be moved back: the edit guard keeps it)
  await h.as(pleb);
  await h.q(`insert into messages (channel_id, author_id, content) values ($1,$2,'later')`, [gen, pleb]);
  h.eq('counter reset by a new message', (await h.one(`select album_n from post_marks where author_id = $1`, [pleb])).album_n, 0);
  await h.ok('and a new album can follow', () => ins(pic(30)));
}
