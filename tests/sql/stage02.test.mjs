export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');

  await h.as(a);
  await h.q(`update profiles set bio='founder of Yapper', avatar_path=$2, banner_path=$3, banner_y=20 where id=$1`,
    [a, `${a}/rat.gif`, `${a}/banner.gif`]);
  const p = await h.one(`select bio, avatar_path, banner_y from profiles where id=$1`, [a]);
  h.eq('profile saved', [p.bio, p.avatar_path, p.banner_y], ['founder of Yapper', `${a}/rat.gif`, 20]);

  await h.fails('avatar must be in own folder', `update profiles set avatar_path=$2 where id=$1`, [a, `${b}/x.png`]);
  await h.fails('bio length limited', `update profiles set bio=repeat('a', 191) where id=$1`, [a]);
  await h.fails('banner position bounded', `update profiles set banner_x=101 where id=$1`, [a]);
  await h.fails('username taken (any case)', `update profiles set username='BOB' where id=$1`, [a]);
  await h.fails('bad username chars', `update profiles set username='no spaces' where id=$1`, [a]);
  await h.q(`update profiles set username='Alice_2' where id=$1`, [a]);
  h.eq('rename works', (await h.one(`select username from profiles where id=$1`, [a])).username, 'Alice_2');

  // Storage folders
  await h.q(`insert into storage.objects (bucket_id, name) values ('avatars', $1)`, [`${a}/1.gif`]);
  await h.fails('cannot upload to someone else folder', `insert into storage.objects (bucket_id, name) values ('avatars', $1)`, [`${b}/1.gif`]);
  await h.fails('cannot upload to unknown bucket', `insert into storage.objects (bucket_id, name) values ('nope', $1)`, [`${a}/1.gif`]);
}
