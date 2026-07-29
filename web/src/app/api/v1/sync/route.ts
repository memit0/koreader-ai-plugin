import { NextResponse } from "next/server";
import { getAdminClient } from "@/lib/supabase";
import { authenticateDevice } from "@/lib/device";

export const dynamic = "force-dynamic";

type BookPayload = { uuid: string; title?: string; authors?: string; md5?: string };
type ItemPayload = {
  uuid: string; book_uuid: string; datetime?: string; text?: string;
  note?: string; chapter?: string; pageno?: number;
};
type MessagePayload = { ordinal: number; role: string; content: string };
type ConversationPayload = {
  uuid: string; book_uuid: string; kind?: string; highlight?: string;
  chapter?: string; pageno?: number; annotation_datetime?: string;
  model?: string; created_at?: number; messages?: MessagePayload[];
};

/** The device sends unix seconds. */
function toIso(seconds?: number): string {
  if (!seconds || !Number.isFinite(seconds)) return new Date().toISOString();
  return new Date(seconds * 1000).toISOString();
}

/**
 * POST /api/v1/sync
 *   { books: [...], items: [...] }  or  { books: [...], conversations: [...] }
 *
 * Every row is matched on (user_id, uuid), so re-sending a batch the device
 * already sent — which happens whenever wifi drops mid-sync — updates in place
 * rather than duplicating. That is what lets the device retry blindly.
 */
export async function POST(request: Request) {
  const device = await authenticateDevice(request);
  if (!device) {
    return NextResponse.json({ error: "Unknown or missing device token." }, { status: 401 });
  }

  let body: { books?: BookPayload[]; items?: ItemPayload[]; conversations?: ConversationPayload[] };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Malformed request body." }, { status: 400 });
  }

  const admin = getAdminClient();
  const userId = device.user_id;
  const books = body.books ?? [];
  const items = body.items ?? [];
  const conversations = body.conversations ?? [];

  // Books first: everything else references them.
  if (books.length > 0) {
    const { error } = await admin.from("books").upsert(
      books.map((book) => ({
        user_id: userId,
        uuid: book.uuid,
        title: book.title ?? "",
        authors: book.authors ?? "",
        md5: book.md5 ?? null,
        updated_at: new Date().toISOString(),
      })),
      { onConflict: "user_id,uuid" },
    );
    if (error) {
      return NextResponse.json({ error: `Could not save books: ${error.message}` }, { status: 500 });
    }
  }

  // Resolve the device's book uuids to our ids.
  const referenced = new Set<string>([
    ...items.map((item) => item.book_uuid),
    ...conversations.map((conversation) => conversation.book_uuid),
  ]);
  const bookIds = new Map<string, string>();
  if (referenced.size > 0) {
    const { data } = await admin
      .from("books")
      .select("id, uuid")
      .eq("user_id", userId)
      .in("uuid", Array.from(referenced));
    for (const row of data ?? []) bookIds.set(row.uuid, row.id);
  }

  const unknown = Array.from(referenced).filter((uuid) => !bookIds.has(uuid));
  if (unknown.length > 0) {
    // The device always sends a batch's books alongside it, so this means the
    // payload was inconsistent. Rejecting keeps the device's rows dirty, and it
    // will send them again with their books.
    return NextResponse.json(
      { error: `Batch references unknown books: ${unknown.join(", ")}` },
      { status: 400 },
    );
  }

  let accepted = 0;

  if (items.length > 0) {
    const { error } = await admin.from("items").upsert(
      items.map((item) => ({
        user_id: userId,
        book_id: bookIds.get(item.book_uuid)!,
        uuid: item.uuid,
        datetime: item.datetime ?? null,
        text: item.text ?? null,
        note: item.note ?? null,
        chapter: item.chapter ?? null,
        pageno: item.pageno ?? null,
        updated_at: new Date().toISOString(),
      })),
      { onConflict: "user_id,uuid" },
    );
    if (error) {
      return NextResponse.json({ error: `Could not save highlights: ${error.message}` }, { status: 500 });
    }
    accepted += items.length;
  }

  if (conversations.length > 0) {
    const { data: saved, error } = await admin
      .from("conversations")
      .upsert(
        conversations.map((conversation) => ({
          user_id: userId,
          book_id: bookIds.get(conversation.book_uuid)!,
          uuid: conversation.uuid,
          kind: conversation.kind ?? "explain",
          highlight: conversation.highlight ?? null,
          chapter: conversation.chapter ?? null,
          pageno: conversation.pageno ?? null,
          annotation_datetime: conversation.annotation_datetime ?? null,
          model: conversation.model ?? null,
          created_at: toIso(conversation.created_at),
          updated_at: new Date().toISOString(),
        })),
        { onConflict: "user_id,uuid" },
      )
      .select("id, uuid");
    if (error) {
      return NextResponse.json({ error: `Could not save explanations: ${error.message}` }, { status: 500 });
    }

    const idByUuid = new Map((saved ?? []).map((row) => [row.uuid, row.id]));

    // Messages are replaced wholesale. Sync is push-only and a conversation only
    // ever grows, so the incoming thread is authoritative; this also keeps a
    // re-sent batch from doubling up the turns.
    const conversationIds = Array.from(idByUuid.values());
    if (conversationIds.length > 0) {
      await admin.from("messages").delete().in("conversation_id", conversationIds);
    }

    const rows = conversations.flatMap((conversation) =>
      (conversation.messages ?? []).map((message) => ({
        conversation_id: idByUuid.get(conversation.uuid)!,
        ordinal: message.ordinal,
        role: message.role,
        content: message.content,
      })),
    );
    if (rows.length > 0) {
      const { error: messageError } = await admin.from("messages").insert(rows);
      if (messageError) {
        return NextResponse.json(
          { error: `Could not save the conversation: ${messageError.message}` },
          { status: 500 },
        );
      }
    }
    accepted += conversations.length;
  }

  await admin
    .from("devices")
    .update({ last_seen_at: new Date().toISOString() })
    .eq("id", device.id);

  return NextResponse.json({ accepted });
}
