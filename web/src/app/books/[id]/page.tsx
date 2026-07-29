import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { getServerClient } from "@/lib/supabase";

export const dynamic = "force-dynamic";

type Item = {
  id: string; datetime: string | null; text: string | null; note: string | null;
  chapter: string | null; pageno: number | null;
};
type Message = { ordinal: number; role: string; content: string };
type Conversation = {
  id: string; kind: string; highlight: string | null; chapter: string | null;
  pageno: number | null; annotation_datetime: string | null; model: string | null;
  created_at: string; messages: Message[];
};

/** A highlight with whatever hangs off it: the reader's note, and any
 *  explanations recorded against it. */
type Entry = {
  key: string;
  chapter: string | null;
  pageno: number | null;
  passage: string | null;
  note: string | null;
  conversations: Conversation[];
};

function buildEntries(items: Item[], conversations: Conversation[]): Entry[] {
  const byAnnotation = new Map<string, Conversation[]>();
  const orphans: Conversation[] = [];

  for (const conversation of conversations) {
    // Explanations saved with save_to_notes off have no annotation to sit under
    const key = conversation.annotation_datetime;
    if (!key) {
      orphans.push(conversation);
      continue;
    }
    const bucket = byAnnotation.get(key);
    if (bucket) bucket.push(conversation);
    else byAnnotation.set(key, [conversation]);
  }

  const entries: Entry[] = items.map((item) => ({
    key: `item-${item.id}`,
    chapter: item.chapter,
    pageno: item.pageno,
    passage: item.text,
    note: item.note,
    conversations: (item.datetime && byAnnotation.get(item.datetime)) || [],
  }));

  for (const conversation of orphans) {
    entries.push({
      key: `conversation-${conversation.id}`,
      chapter: conversation.chapter,
      pageno: conversation.pageno,
      passage: conversation.highlight,
      note: null,
      conversations: [conversation],
    });
  }

  // Reading order, with unpaged entries last
  return entries.sort((a, b) => (a.pageno ?? 1e9) - (b.pageno ?? 1e9));
}

/** Ordinal 1 is the passage we sent as the prompt, so it is not worth repeating;
 *  ordinal 2 is the explanation; anything after that is a follow-up exchange. */
function splitThread(messages: Message[]) {
  const ordered = [...messages].sort((a, b) => a.ordinal - b.ordinal);
  const explanation = ordered.find((m) => m.role === "assistant");
  const followUps = ordered.filter(
    (m) => m.ordinal > (explanation?.ordinal ?? 2),
  );
  return { explanation, followUps };
}

export default async function BookPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await getServerClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect("/login");

  const { data: book } = await supabase
    .from("books")
    .select("id, title, authors")
    .eq("id", id)
    .maybeSingle();
  if (!book) notFound();

  const [{ data: itemData }, { data: conversationData }] = await Promise.all([
    supabase
      .from("items")
      .select("id, datetime, text, note, chapter, pageno")
      .eq("book_id", id)
      .order("pageno", { ascending: true }),
    supabase
      .from("conversations")
      .select(
        "id, kind, highlight, chapter, pageno, annotation_datetime, model, created_at, messages(ordinal, role, content)",
      )
      .eq("book_id", id)
      .order("pageno", { ascending: true }),
  ]);

  const entries = buildEntries(
    (itemData ?? []) as Item[],
    (conversationData ?? []) as Conversation[],
  );

  return (
    <>
      <p className="subtitle" style={{ marginBottom: "0.5rem" }}>
        <Link href="/">← Library</Link>
      </p>
      <h1>{book.title || "Untitled"}</h1>
      <p className="subtitle">{book.authors || "Unknown author"}</p>

      {entries.length === 0 ? (
        <p className="empty">Nothing synced for this book yet.</p>
      ) : (
        entries.map((entry) => (
          <article className="entry" key={entry.key}>
            {(entry.chapter || entry.pageno) && (
              <p className="locator">
                {[entry.chapter, entry.pageno ? `p. ${entry.pageno}` : null]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            )}

            {entry.passage && (
              <blockquote className="passage">{entry.passage}</blockquote>
            )}

            {entry.note && (
              <div className="note">
                <span className="label">Your note</span>
                {entry.note}
              </div>
            )}

            {entry.conversations.map((conversation) => {
              const { explanation, followUps } = splitThread(conversation.messages ?? []);
              return (
                <div className="explanation" key={conversation.id}>
                  <span className="label">
                    {conversation.kind === "translate" ? "Translation" : "Explanation"}
                    {conversation.model ? ` · ${conversation.model}` : ""}
                  </span>
                  {explanation?.content}
                  {followUps.map((message) => (
                    <div className="turn" key={message.ordinal}>
                      <span className="who">
                        {message.role === "user" ? "You" : "Reply"}
                      </span>
                      <div>{message.content}</div>
                    </div>
                  ))}
                </div>
              );
            })}
          </article>
        ))
      )}
    </>
  );
}
