// delete-account — completes in-app account deletion (master prompt §18).
//
// The SQL RPC public.delete_account() anonymises and tears down app data immediately, but it
// cannot remove storage objects or the auth user itself. This Edge Function finishes the job
// with the service role:
//   1. Authenticate the caller from their JWT.
//   2. Run delete_account() AS the caller (anonymise + soft-delete their data).
//   3. Delete their avatar folder from the `avatars` bucket.
//   4. Delete their post-photo folder from the `post-images` bucket.
//   5. Delete the auth user (which cascades and removes the profile + remaining rows).
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

  // 3-5 need elevated privileges.
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 3. Remove the user's avatar folder, and everything nested under it. If this fails, we
  // abort BEFORE deleting the auth user (step 5) rather than pressing on: step 2's
  // delete_account() RPC is idempotent (re-anonymises already-anonymised rows, deletes
  // already-deleted rows), so leaving the auth user intact means the client can safely retry
  // the whole request. Proceeding anyway would let step 5's cascade hard-delete the rows that
  // name these objects, orphaning whatever's left in the bucket permanently with nothing left
  // in the database to enumerate or retry against.
  const avatarsResult = await emptyUserFolder(admin, "avatars", userId);
  if (!avatarsResult.ok) {
    return json({ error: `storage cleanup failed: ${avatarsResult.error}` }, 500);
  }

  // 4. Remove the user's post-photo folder, and everything nested under it. Without this,
  // step 5's cascade (auth.users → profiles → posts) hard-deletes the posts rows that hold the
  // only copies of image_path, stranding the objects themselves in a public = true bucket
  // (supabase/migrations/20260811000200_feed_storage.sql:12-14) — fetchable with no
  // Authorization header, forever, with nothing left in the database to enumerate them. Same
  // abort-before-auth-deletion reasoning as step 3 applies here.
  const postImagesResult = await emptyUserFolder(admin, "post-images", userId);
  if (!postImagesResult.ok) {
    return json({ error: `storage cleanup failed: ${postImagesResult.error}` }, 500);
  }

  // 5. Delete the auth user (cascades to profile + any remaining rows).
  const { error: delErr } = await admin.auth.admin.deleteUser(userId);
  if (delErr) return json({ error: `auth deletion failed: ${delErr.message}` }, 500);

  return json({ deleted: true });
});

// Recursively empties every object under `<bucket>/<rootPrefix>/`, including nested
// "folders" (storage.list() is not recursive — an object at "<rootPrefix>/sub/x.jpg" shows up
// in list(rootPrefix) as a folder entry named "sub", not as the file itself, and remove() does
// not delete into folders). Supabase's only signal that a list() entry is a folder rather than
// a file is `id === null` (real objects always have a storage object id) — there is no `type`
// or `is_dir` field, so that null check is a behavioural detail of the API, not a documented
// contract, and is worth flagging if a future supabase-js upgrade changes list()'s shape.
//
// Pagination relies on remove() shrinking the list: with no offset, list(prefix, { limit })
// keeps returning "the next pageSize items" only because the previous page's files were just
// deleted. Folder entries are NOT removed directly (remove() can't delete a prefix), so they
// keep reappearing in list(prefix) until their own contents are emptied via the queue below —
// the `queued` set stops the same folder from being enqueued again on every page it appears in.
//
// Bounded by two independent limits: (1) `remove()` errors abort immediately instead of
// retrying — list() would return the exact same page forever otherwise, spinning until the
// platform kills the request; (2) MAX_LIST_ITERATIONS is a defensive backstop against any
// future change reintroducing an unbounded loop (each iteration is one list() call for one
// page, so this bounds total objects handled to roughly MAX_LIST_ITERATIONS * pageSize).
const MAX_LIST_ITERATIONS = 10_000;

async function emptyUserFolder(
  // deno-lint-ignore no-explicit-any
  admin: any,
  bucket: string,
  rootPrefix: string,
): Promise<{ ok: true } | { ok: false; error: string }> {
  const pageSize = 100;
  const queue: string[] = [rootPrefix];
  const queued = new Set<string>([rootPrefix]);
  let iterations = 0;

  while (queue.length > 0) {
    const prefix = queue.shift()!;

    // Page through this one prefix until it's exhausted (a short page means "done").
    while (true) {
      if (++iterations > MAX_LIST_ITERATIONS) {
        return {
          ok: false,
          error: `${bucket}: exceeded ${MAX_LIST_ITERATIONS} list iterations without finishing`,
        };
      }

      const { data: entries, error: listErr } = await admin.storage
        .from(bucket)
        .list(prefix, { limit: pageSize });
      if (listErr) return { ok: false, error: `${bucket} list failed: ${listErr.message}` };
      if (!entries || entries.length === 0) break;

      const filePaths: string[] = [];
      // deno-lint-ignore no-explicit-any
      for (const entry of entries as any[]) {
        const path = `${prefix}/${entry.name}`;
        if (entry.id === null) {
          if (!queued.has(path)) {
            queued.add(path);
            queue.push(path);
          }
        } else {
          filePaths.push(path);
        }
      }

      if (filePaths.length > 0) {
        const { error: removeErr } = await admin.storage.from(bucket).remove(filePaths);
        if (removeErr) return { ok: false, error: `${bucket} remove failed: ${removeErr.message}` };
      } else {
        // Every entry on this page was an already-queued folder — nothing here for remove()
        // to shrink the listing by, so relisting would return the same page forever. The
        // folders queued above will empty (and so stop appearing here) once their turn comes.
        // Known limitation of this simple queue: if a single prefix has MORE than pageSize
        // direct sibling folders (not files — folders), any beyond the first page are never
        // discovered, since we don't track an offset here. Not reachable through normal app
        // usage (posts/avatars are uploaded as flat files, not deeply/widely nested trees).
        break;
      }

      if (entries.length < pageSize) break;
    }
  }

  return { ok: true };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
