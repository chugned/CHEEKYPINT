// delete-account — completes in-app account deletion (master prompt §18).
//
// The SQL RPC public.delete_account() anonymises and tears down app data immediately, but it
// cannot remove storage objects or the auth user itself. This Edge Function finishes the job
// with the service role:
//   1. Authenticate the caller from their JWT.
//   2. Run delete_account() AS the caller (anonymise + soft-delete their data).
//   3. Delete their avatar folder from the `avatars` bucket.
//   4. Delete the auth user (which cascades and removes the profile + remaining rows).
//
// The service-role key lives ONLY in the Edge Function environment and never touches the app.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // A client acting AS the caller (RLS + auth.uid() apply).
  const asUser = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userErr } = await asUser.auth.getUser();
  if (userErr || !userData?.user) return json({ error: "Not authenticated" }, 401);
  const userId = userData.user.id;

  // 2. Anonymise + tear down app data as the user.
  const { error: rpcErr } = await asUser.rpc("delete_account");
  if (rpcErr) return json({ error: `delete_account failed: ${rpcErr.message}` }, 400);

  // 3 + 4 need elevated privileges.
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 3. Remove the user's avatar folder.
  const { data: files } = await admin.storage.from("avatars").list(userId);
  if (files && files.length > 0) {
    const paths = files.map((f) => `${userId}/${f.name}`);
    await admin.storage.from("avatars").remove(paths);
  }

  // 4. Delete the auth user (cascades to profile + any remaining rows).
  const { error: delErr } = await admin.auth.admin.deleteUser(userId);
  if (delErr) return json({ error: `auth deletion failed: ${delErr.message}` }, 500);

  return json({ deleted: true });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
