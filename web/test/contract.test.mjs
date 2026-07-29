/**
 * Runs the payloads the KOReader plugin actually produces through the sync
 * route, with Supabase faked in memory. This is the contract test: it fails if
 * either side renames a field, which is exactly the drift that is otherwise
 * invisible until a device in the wild cannot sync.
 *
 *   node --test web/test/contract.test.mjs
 *
 * Regenerate the fixture with:  lua5.1 test/dump_payload.lua
 */
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(
  readFileSync(resolve(here, "../../test/fixtures/payloads.json"), "utf8"),
);

// --- in-memory Supabase -----------------------------------------------------

function makeDatabase() {
  return {
    devices: [
      {
        id: "device-1",
        user_id: "user-1",
        device_uuid: fixture.pair.device_uuid,
        token_hash: createHash("sha256").update("device-token").digest("hex"),
      },
    ],
    pairing_codes: [],
    books: [],
    items: [],
    conversations: [],
    messages: [],
  };
}

let db = makeDatabase();

function makeQuery(table) {
  const state = { filters: [], rows: null };
  const api = {
    select() {
      state.rows = db[table];
      return api;
    },
    eq(column, value) {
      state.filters.push((row) => row[column] === value);
      return api;
    },
    in(column, values) {
      state.filters.push((row) => values.includes(row[column]));
      return api;
    },
    _matched() {
      return (state.rows ?? db[table]).filter((row) =>
        state.filters.every((f) => f(row)),
      );
    },
    maybeSingle() {
      return Promise.resolve({ data: api._matched()[0] ?? null, error: null });
    },
    upsert(rows, options) {
      const keys = (options?.onConflict ?? "").split(",").filter(Boolean);
      const saved = [];
      for (const row of [rows].flat()) {
        const existing = keys.length
          ? db[table].find((candidate) => keys.every((k) => candidate[k] === row[k]))
          : undefined;
        if (existing) {
          Object.assign(existing, row);
          saved.push(existing);
        } else {
          const created = { id: `${table}-${db[table].length + 1}`, ...row };
          db[table].push(created);
          saved.push(created);
        }
      }
      const result = { data: saved, error: null };
      return Object.assign(Promise.resolve(result), {
        select: () => Promise.resolve(result),
      });
    },
    insert(rows) {
      for (const row of [rows].flat()) {
        db[table].push({ id: `${table}-${db[table].length + 1}`, ...row });
      }
      return Promise.resolve({ data: null, error: null });
    },
    update(patch) {
      const chained = {
        eq(column, value) {
          for (const row of db[table]) {
            if (row[column] === value) Object.assign(row, patch);
          }
          return Promise.resolve({ error: null });
        },
      };
      return chained;
    },
    delete() {
      return {
        in(column, values) {
          db[table] = db[table].filter((row) => !values.includes(row[column]));
          return Promise.resolve({ error: null });
        },
      };
    },
    then(onFulfilled) {
      return Promise.resolve({ data: api._matched(), error: null }).then(onFulfilled);
    },
  };
  return api;
}

const fakeClient = { from: (table) => makeQuery(table) };

process.env.NEXT_PUBLIC_SUPABASE_URL = "https://x.supabase.co";
process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon";
process.env.SUPABASE_SERVICE_ROLE_KEY = "service";

globalThis.__FAKE_SUPABASE__ = fakeClient;

const requireCjs = createRequire(import.meta.url);
const { POST: syncRoute } = requireCjs("./compiled/sync.route.cjs");

function request(body, token = "device-token") {
  return new Request("https://example.com/api/v1/sync", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

test("device payloads are accepted as-is", async () => {
  db = makeDatabase();
  for (const payload of fixture.sync) {
    const response = await syncRoute(request(payload));
    const json = await response.json();
    assert.equal(response.status, 200, JSON.stringify(json));
  }

  assert.equal(db.books.length, 1, "one book stored");
  assert.equal(db.books[0].title, "Critique of Pure Reason");
  assert.equal(db.items.length, 1, "one highlight stored");
  assert.equal(db.items[0].note, "worth rereading", "the reader's own note survives");
  assert.equal(db.conversations.length, 1, "one conversation stored");
  assert.equal(db.messages.length, 4, "all four turns stored");
});

test("records are linked to their book", async () => {
  db = makeDatabase();
  for (const payload of fixture.sync) await syncRoute(request(payload));
  const bookId = db.books[0].id;
  assert.equal(db.items[0].book_id, bookId);
  assert.equal(db.conversations[0].book_id, bookId);
  assert.equal(
    db.conversations[0].annotation_datetime,
    db.items[0].datetime,
    "explanation resolves to the highlight it belongs to",
  );
});

test("re-sending a batch does not duplicate", async () => {
  db = makeDatabase();
  for (const round of [1, 2, 3]) {
    void round;
    for (const payload of fixture.sync) await syncRoute(request(payload));
  }
  assert.equal(db.books.length, 1, "book upserted, not duplicated");
  assert.equal(db.items.length, 1, "highlight upserted, not duplicated");
  assert.equal(db.conversations.length, 1, "conversation upserted, not duplicated");
  assert.equal(db.messages.length, 4, "messages replaced, not appended");
});

test("an unknown token is rejected", async () => {
  db = makeDatabase();
  const response = await syncRoute(request(fixture.sync[0], "not-a-real-token"));
  assert.equal(response.status, 401);
  assert.equal(db.books.length, 0, "nothing written for an unauthenticated device");
});

test("a batch referencing a missing book is refused", async () => {
  db = makeDatabase();
  const response = await syncRoute(
    request({ conversations: [{ uuid: "x", book_uuid: "never-sent", messages: [] }] }),
  );
  assert.equal(response.status, 400, "rejected so the device retries with the book");
  assert.equal(db.conversations.length, 0);
});
