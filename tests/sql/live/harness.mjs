// Same test API as tests/sql/harness.mjs (signup, as, admin, q, one, ok, fails, eq), but against a real Postgres
// that holds the live schema dump (schema/*.sql) instead of PGlite replaying migrations. Each test file gets its own
// database, copied from a template that was restored once, so tests can't see each other's rows.
//
// Connection comes from the usual PG* environment variables (PGHOST, PGPORT, PGUSER, PGPASSWORD).
import pg from 'pg';

// bigint (count(*), ids from sequences) as a JS number, like PGlite does.
pg.types.setTypeParser(20, (v) => Number(v));

// What the stage tests do with db.exec / db.query, on top of a pg client.
class Db {
  constructor(client) { this.client = client; this.guard = null; }
  async exec(sql) {
    this.guard?.(sql);
    await this.client.query(sql);
  }
  async query(sql, params = []) {
    this.guard?.(sql);
    const r = await this.client.query(sql, params);
    return { rows: r.rows };
  }
}

export class Harness {
  constructor(client) {
    this.db = new Db(client);
    this.passed = 0;
  }
  async signup(email, username) {
    const meta = username ? JSON.stringify({ username }) : '{}';
    await this.admin();
    const r = await this.db.query(
      `insert into auth.users (email, raw_user_meta_data, email_confirmed_at) values ($1, $2::jsonb, now()) returning id`,
      [email, meta],
    );
    return r.rows[0].id;
  }
  async admin() {
    await this.db.client.query(`reset role; select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '', false);`);
  }
  // Signs in like PostgREST does: the JWT claims go in request.jwt.claims, then the role switches.
  async as(userId) {
    await this.db.client.query('reset role');
    const claims = userId ? { sub: userId, role: 'authenticated', aal: 'aal1' } : { role: 'anon' };
    await this.db.client.query(
      `select set_config('request.jwt.claims', $1, false), set_config('request.jwt.claim.sub', $2, false)`,
      [JSON.stringify(claims), userId ?? ''],
    );
    await this.db.client.query(`set role ${userId ? 'authenticated' : 'anon'}`);
    return this;
  }
  async q(sql, params = []) {
    return (await this.db.query(sql, params)).rows;
  }
  async one(sql, params = []) {
    return (await this.q(sql, params))[0];
  }
  async ok(name, fn) {
    try {
      await fn();
      this.passed++;
    } catch (e) {
      throw new Error(`✗ ${name}: ${e.message}`);
    }
  }
  // Runs in a savepoint-free way: pg leaves the connection usable after a failed statement outside a transaction.
  async fails(name, sql, params = []) {
    let threw = false;
    try {
      await this.db.query(sql, params);
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`✗ ${name}: expected an error but the query succeeded`);
    this.passed++;
  }
  eq(name, actual, expected) {
    const a = JSON.stringify(actual);
    const b = JSON.stringify(expected);
    if (a !== b) throw new Error(`✗ ${name}: expected ${b}, got ${a}`);
    this.passed++;
  }
}
