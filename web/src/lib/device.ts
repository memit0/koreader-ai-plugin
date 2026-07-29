import { createHash, randomBytes } from "node:crypto";
import { getAdminClient } from "@/lib/supabase";

/** Only the hash is ever stored, so a database leak does not hand out device
 *  tokens. */
export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function generateToken(): string {
  return randomBytes(32).toString("base64url");
}

/** Codes are typed on an e-ink keyboard, so: short, upper case, and without the
 *  characters that are easy to misread (0/O, 1/I). */
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function generatePairingCode(length = 6): string {
  const bytes = randomBytes(length);
  let code = "";
  for (let i = 0; i < length; i += 1) {
    code += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return code;
}

export type Device = { id: string; user_id: string };

/** Resolves `Authorization: Bearer <token>` to the device that owns it. */
export async function authenticateDevice(
  request: Request,
): Promise<Device | null> {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;

  const admin = getAdminClient();
  const { data } = await admin
    .from("devices")
    .select("id, user_id")
    .eq("token_hash", hashToken(match[1]))
    .maybeSingle();

  return data ?? null;
}
