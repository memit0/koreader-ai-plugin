import { NextResponse } from "next/server";
import { getServerClient } from "@/lib/supabase";

export const dynamic = "force-dynamic";

/** Completes the magic-link sign in and drops the reader at their library. */
export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");

  if (code) {
    const supabase = await getServerClient();
    await supabase.auth.exchangeCodeForSession(code);
  }

  return NextResponse.redirect(new URL("/", url.origin));
}
