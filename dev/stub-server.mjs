/**
 * A stand-in for the sync endpoint, so the plugin's pairing and sync can be
 * exercised with no Supabase project and no deploy. Node only, no dependencies.
 *
 *     node dev/stub-server.mjs            # listens on 4000
 *     PORT=5000 node dev/stub-server.mjs
 *
 * Then in the simulator:
 *     LUNOTE_SYNC_URL=http://127.0.0.1:4000 ./dev/lunote-sim
 *     lunote> pair ANYCODE
 *     lunote> sync
 *
 * It accepts any pairing code, prints every payload it receives, and keeps the
 * records in memory with the same (uuid) keying the real server uses — so
 * re-sending a batch is visibly a no-op here too. GET / shows what it holds.
 */
import { createServer } from "node:http";
import { randomBytes } from "node:crypto";

const port = Number(process.env.PORT ?? 4000);

const store = {
  tokens: new Map(), // token -> device_uuid
  books: new Map(),
  items: new Map(),
  conversations: new Map(),
};

let requestCount = 0;

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function json(response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  response.end(payload);
}

function summarise(payload) {
  const parts = [];
  if (payload.books?.length) parts.push(`${payload.books.length} book(s)`);
  if (payload.items?.length) parts.push(`${payload.items.length} highlight(s)`);
  if (payload.conversations?.length) {
    const turns = payload.conversations.reduce(
      (total, conversation) => total + (conversation.messages?.length ?? 0),
      0,
    );
    parts.push(`${payload.conversations.length} conversation(s), ${turns} turn(s)`);
  }
  return parts.join(", ") || "nothing";
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);

  if (request.method === "GET" && url.pathname === "/") {
    return json(response, 200, {
      devices: store.tokens.size,
      books: [...store.books.values()],
      items: [...store.items.values()],
      conversations: [...store.conversations.values()],
    });
  }

  if (request.method !== "POST") return json(response, 404, { error: "not found" });

  let payload;
  try {
    payload = await readBody(request);
  } catch {
    return json(response, 400, { error: "malformed body" });
  }

  requestCount += 1;

  if (url.pathname === "/api/v1/pair") {
    // Any code is accepted; this is a stub, not an auth system
    const token = randomBytes(16).toString("base64url");
    store.tokens.set(token, payload.device_uuid);
    console.log(
      `#${requestCount} pair   code=${payload.code} device=${payload.device_uuid} ` +
        `name=${payload.device_name ?? "?"} -> token ${token.slice(0, 8)}…`,
    );
    return json(response, 200, { token });
  }

  if (url.pathname === "/api/v1/sync") {
    const token = (request.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
    if (!store.tokens.has(token)) {
      console.log(`#${requestCount} sync   REJECTED: unknown token`);
      return json(response, 401, { error: "unknown device token" });
    }

    const before =
      store.books.size + store.items.size + store.conversations.size;

    for (const book of payload.books ?? []) store.books.set(book.uuid, book);
    for (const item of payload.items ?? []) store.items.set(item.uuid, item);
    for (const conversation of payload.conversations ?? []) {
      store.conversations.set(conversation.uuid, conversation);
    }

    const after = store.books.size + store.items.size + store.conversations.size;
    console.log(
      `#${requestCount} sync   ${summarise(payload)}  ` +
        `(${after - before} new, ${after} held)`,
    );
    for (const item of payload.items ?? []) {
      console.log(`         highlight “${(item.text ?? "").slice(0, 60)}”` +
        (item.note ? `  note: “${item.note.slice(0, 40)}”` : ""));
    }
    for (const conversation of payload.conversations ?? []) {
      console.log(`         ${conversation.kind} on “${(conversation.highlight ?? "").slice(0, 50)}”` +
        `  model=${conversation.model ?? "?"}`);
    }

    return json(response, 200, { accepted: (payload.items?.length ?? 0) +
      (payload.conversations?.length ?? 0) });
  }

  return json(response, 404, { error: "not found" });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`stub sync server on http://127.0.0.1:${port}`);
  console.log("point the simulator at it:");
  console.log(`  LUNOTE_SYNC_URL=http://127.0.0.1:${port} ./dev/lunote-sim\n`);
});
