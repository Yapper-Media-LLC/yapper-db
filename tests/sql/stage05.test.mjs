export default async function (h) {
  const a = await h.signup('alice@test.dev', 'alice');
  const b = await h.signup('bob@test.dev', 'bob');
  await h.as(a);
  const dm = (await h.one(`select get_or_create_dm($1) id`, [b])).id;

  const pic = (await h.one(
    `insert into messages (channel_id, author_id, content, attachment_path, attachment_width, attachment_height)
     values ($1,$2,'',$3,800,600) returning id`, [dm, a, `${a}/meme.gif`])).id;
  h.eq('picture without text is ok', !!pic, true);
  await h.q(`insert into messages (channel_id, author_id, content, attachment_path) values ($1,$2,'look',$3)`, [dm, a, `${a}/m2.png`]);
  await h.fails('nothing at all is rejected', `insert into messages (channel_id, author_id, content) values ($1,$2,'   ')`, [dm, a]);
  await h.fails("can't attach someone else's file", `insert into messages (channel_id, author_id, content, attachment_path) values ($1,$2,'',$3)`, [dm, a, `${b}/x.png`]);

  await h.q(`update messages set content='caption', attachment_path=$2 where id=$1`, [pic, `${a}/other.png`]);
  const r = await h.one(`select content, attachment_path from messages where id=$1`, [pic]);
  h.eq('edit keeps the picture', [r.content, r.attachment_path], ['caption', `${a}/meme.gif`]);

  await h.q(`insert into storage.objects (bucket_id, name) values ('attachments', $1)`, [`${a}/meme.gif`]);
  await h.fails('upload only to own folder', `insert into storage.objects (bucket_id, name) values ('attachments', $1)`, [`${b}/meme.gif`]);
}
