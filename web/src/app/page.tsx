import Link from "next/link";
import { redirect } from "next/navigation";
import { getServerClient } from "@/lib/supabase";

export const dynamic = "force-dynamic";

type BookSummary = {
  id: string;
  title: string;
  authors: string;
  updated_at: string;
  item_count: number;
  note_count: number;
  conversation_count: number;
};

function plural(count: number, singular: string, plural_: string) {
  return `${count} ${count === 1 ? singular : plural_}`;
}

export default async function BooksPage() {
  const supabase = await getServerClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect("/login");

  const { data } = await supabase
    .from("book_summaries")
    .select("*")
    .order("updated_at", { ascending: false });

  const books = (data ?? []) as BookSummary[];

  return (
    <>
      <h1>Your library</h1>
      <p className="subtitle">
        {books.length === 0
          ? "Nothing synced yet."
          : plural(books.length, "book", "books")}
      </p>

      {books.length === 0 ? (
        <p className="empty">
          Pair your e-reader, then tap <strong>Sync to web app</strong> in
          KOReader&rsquo;s AskGPT menu.
        </p>
      ) : (
        <ul className="book-list">
          {books.map((book) => (
            <li key={book.id}>
              <Link href={`/books/${book.id}`} className="book-card">
                <h2>{book.title || "Untitled"}</h2>
                <p className="authors">{book.authors || "Unknown author"}</p>
                <div className="counts">
                  <span>{plural(book.item_count, "highlight", "highlights")}</span>
                  <span>{plural(book.note_count, "note", "notes")}</span>
                  <span>
                    {plural(book.conversation_count, "explanation", "explanations")}
                  </span>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
