import { redirect } from "next/navigation";
import { getServerClient } from "@/lib/supabase";

export const dynamic = "force-dynamic";

async function sendMagicLink(formData: FormData) {
  "use server";
  const email = String(formData.get("email") ?? "").trim();
  if (!email) return;

  const supabase = await getServerClient();
  await supabase.auth.signInWithOtp({
    email,
    options: {
      emailRedirectTo: `${process.env.NEXT_PUBLIC_SITE_URL ?? ""}/auth/callback`,
    },
  });
  redirect("/login?sent=1");
}

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ sent?: string }>;
}) {
  const { sent } = await searchParams;
  const supabase = await getServerClient();
  const { data: auth } = await supabase.auth.getUser();
  if (auth.user) redirect("/");

  return (
    <>
      <h1>Sign in</h1>
      <p className="subtitle">
        We&rsquo;ll email you a link — no password to remember.
      </p>

      {sent ? (
        <p className="empty">Check your inbox for the sign-in link.</p>
      ) : (
        <form action={sendMagicLink} style={{ display: "flex", gap: "0.5rem" }}>
          <input
            type="email"
            name="email"
            required
            placeholder="you@example.com"
            style={{
              flex: 1,
              font: "inherit",
              padding: "0.6rem 0.8rem",
              borderRadius: "10px",
              border: "1px solid var(--border)",
              background: "var(--surface)",
              color: "var(--ink)",
            }}
          />
          <button type="submit">Send link</button>
        </form>
      )}
    </>
  );
}
