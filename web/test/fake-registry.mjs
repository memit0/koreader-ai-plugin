// Stands in for src/lib/supabase during the contract test. The route is bundled
// with this aliased in its place, so the route's own logic runs untouched.
//
// The fake arrives via a global rather than a module export: the bundler inlines
// this file into the route bundle, so a module-level variable here would be a
// different instance from the one the test holds.
export function getAdminClient() {
  const client = globalThis.__FAKE_SUPABASE__;
  if (!client) throw new Error("no fake Supabase client registered");
  return client;
}

export async function getServerClient() {
  return getAdminClient();
}
