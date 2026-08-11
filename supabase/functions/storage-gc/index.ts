// storage-gc — drains public.storage_gc_queue, the durable record of storage objects whose
// owning row has already been deleted (see supabase/migrations/20260812000200_storage_gc_queue.sql).
//
// SQL cannot delete storage objects itself, so anything that removes a row referencing one
// (account deletion, post deletion, ...) enqueues the object there instead of touching storage
// directly. This function is the only thing that drains that queue, and it runs with the
// service role:
//   1. Reject any caller that does not present the service-role key itself as its bearer token.
//      This function is for scheduled invocation (cron / an ops trigger), never the app, so
//      there is no user JWT to authenticate here the way delete-account authenticates one.
//   2. Claim a batch of unprocessed rows via claim_storage_gc().
//   3. Group the batch by bucket_id and remove() each bucket's objects in one call — remove()
//      takes a single bucket and a list of paths, and different buckets share no path
//      namespace, so they cannot be removed together.
//   4. Mark a bucket's rows done as soon as its OWN remove() call succeeds, rather than waiting
//      for every bucket in the batch to finish. Grouping by bucket_id means we always know
//      exactly which ids belong to the bucket that just succeeded, so marking them done is
//      correct regardless of what happens to any other bucket in the same batch: those objects
//      really are gone from storage. On the first bucket whose remove() fails, stop and return
//      500 with the error. Rows already marked done for earlier buckets stay done. The failed
//      bucket's rows, and any bucket not yet attempted, stay unprocessed (processed_at is still
//      null) and are picked up again by the next scheduled run — there is no retry loop inside
//      this invocation.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// Mirrors the brief's claim_storage_gc(200) call; also comfortably under claim_storage_gc's own
// 500-row cap (supabase/migrations/20260812000200_storage_gc_queue.sql), so it is never clamped.
const CLAIM_LIMIT = 200;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Service role only: the caller must present the service-role key itself, not merely any
  // valid user JWT. There is no "asUser" client in this function at all — unlike delete-account,
  // nothing here ever acts as a particular end user.
  if (authHeader !== `Bearer ${serviceKey}`) {
    return json({ error: "Not authorized" }, 401);
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 2. Claim a batch of unprocessed rows.
  const { data: rows, error: claimErr } = await admin.rpc("claim_storage_gc", {
    p_limit: CLAIM_LIMIT,
  });
  if (claimErr) return json({ error: `claim_storage_gc failed: ${claimErr.message}` }, 500);

  const claimed = (rows ?? []) as { id: string; bucket_id: string; object_path: string }[];
  if (claimed.length === 0) return json({ processed: 0 });

  // 3. Group by bucket_id, preserving each row's id alongside its path so step 4 can mark the
  // right ids done without re-querying.
  const byBucket = new Map<string, { ids: string[]; paths: string[] }>();
  for (const row of claimed) {
    const group = byBucket.get(row.bucket_id) ?? { ids: [], paths: [] };
    group.ids.push(row.id);
    group.paths.push(row.object_path);
    byBucket.set(row.bucket_id, group);
  }

  // 4. Remove and mark done, one bucket at a time. See the module comment for why marking a
  // bucket done as soon as its own remove() succeeds — rather than waiting on the whole batch —
  // is the correct behaviour on partial failure.
  let processed = 0;
  for (const [bucket, group] of byBucket) {
    const { error: removeErr } = await admin.storage.from(bucket).remove(group.paths);
    if (removeErr) {
      return json({ error: `${bucket} remove failed: ${removeErr.message}` }, 500);
    }

    const { error: markErr } = await admin.rpc("mark_storage_gc_done", { p_ids: group.ids });
    if (markErr) {
      return json({ error: `mark_storage_gc_done failed for ${bucket}: ${markErr.message}` }, 500);
    }

    processed += group.ids.length;
  }

  return json({ processed });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
