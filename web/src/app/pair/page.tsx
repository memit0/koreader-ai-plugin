import { redirect } from "next/navigation";
import { getServerClient, getAdminClient } from "@/lib/supabase";
import { generatePairingCode } from "@/lib/device";

export const dynamic = "force-dynamic";

const CODE_TTL_MINUTES = 10;

async function issueCode() {
  "use server";
  const supabase = await getServerClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect("/login");

  const admin = getAdminClient();
  const code = generatePairingCode();
  await admin.from("pairing_codes").insert({
    code,
    user_id: auth.user.id,
    expires_at: new Date(Date.now() + CODE_TTL_MINUTES * 60_000).toISOString(),
  });
  redirect(`/pair?code=${code}`);
}

export default async function PairPage({
  searchParams,
}: {
  searchParams: Promise<{ code?: string }>;
}) {
  const { code } = await searchParams;
  const supabase = await getServerClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect("/login");

  const { data: devices } = await supabase
    .from("devices")
    .select("id, name, device_uuid, last_seen_at")
    .order("last_seen_at", { ascending: false, nullsFirst: false });

  return (
    <>
      <h1>Pair a device</h1>
      <p className="subtitle">
        Generate a code, then type it into KOReader under
        {" "}<strong>Menu → AskGPT → Pair with web app</strong>.
      </p>

      {code ? (
        <>
          <div className="code-display">{code}</div>
          <p className="subtitle">
            Valid for {CODE_TTL_MINUTES} minutes, and usable once.
          </p>
        </>
      ) : (
        <form action={issueCode}>
          <button type="submit">Generate a pairing code</button>
        </form>
      )}

      <h2 style={{ marginTop: "2.5rem" }}>Paired devices</h2>
      {devices && devices.length > 0 ? (
        <ul className="book-list" style={{ marginTop: "0.75rem" }}>
          {devices.map((device) => (
            <li key={device.id} className="book-card">
              <strong>{device.name || "Unnamed device"}</strong>
              <p className="authors">
                {device.last_seen_at
                  ? `Last synced ${new Date(device.last_seen_at).toLocaleString()}`
                  : "Never synced"}
              </p>
            </li>
          ))}
        </ul>
      ) : (
        <p className="subtitle">No devices paired yet.</p>
      )}
    </>
  );
}
