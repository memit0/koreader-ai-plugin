import { NextResponse } from "next/server";
import { getAdminClient } from "@/lib/supabase";
import { generateToken, hashToken } from "@/lib/device";

export const dynamic = "force-dynamic";

/**
 * POST /api/v1/pair
 *   { code, device_uuid, device_name } -> { token }
 *
 * Exchanges the short code shown in the web app for a long-lived device token.
 * The code is single use and expires; the token is stored hashed.
 */
export async function POST(request: Request) {
  let body: { code?: string; device_uuid?: string; device_name?: string };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Malformed request body." }, { status: 400 });
  }

  const code = (body.code ?? "").trim().toUpperCase();
  const deviceUuid = (body.device_uuid ?? "").trim();
  if (!code || !deviceUuid) {
    return NextResponse.json(
      { error: "A pairing code and device id are both required." },
      { status: 400 },
    );
  }

  const admin = getAdminClient();
  const { data: pairing } = await admin
    .from("pairing_codes")
    .select("code, user_id, expires_at, consumed_at")
    .eq("code", code)
    .maybeSingle();

  // One message for every rejection: an attacker guessing codes learns nothing
  // about which part was wrong.
  const invalid = NextResponse.json(
    { error: "That code is not valid any more. Generate a new one." },
    { status: 400 },
  );
  if (!pairing) return invalid;
  if (pairing.consumed_at) return invalid;
  if (new Date(pairing.expires_at).getTime() < Date.now()) return invalid;

  const token = generateToken();
  const { error: deviceError } = await admin.from("devices").upsert(
    {
      user_id: pairing.user_id,
      device_uuid: deviceUuid,
      name: body.device_name ?? null,
      token_hash: hashToken(token),
      last_seen_at: new Date().toISOString(),
    },
    { onConflict: "user_id,device_uuid" },
  );
  if (deviceError) {
    return NextResponse.json({ error: "Could not register the device." }, { status: 500 });
  }

  await admin
    .from("pairing_codes")
    .update({ consumed_at: new Date().toISOString() })
    .eq("code", code);

  return NextResponse.json({ token });
}
