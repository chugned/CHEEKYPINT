-- feed_page and post_comments_page gained cursor arguments after 000500/000600 were first
-- applied. create or replace with a changed signature creates a new function rather than
-- replacing, so any database that ran the earlier files keeps the old overload — still granted,
-- and still carrying the lossy cursor. Dropping is a no-op on a fresh database.
drop function if exists public.feed_page(timestamptz, int);
drop function if exists public.post_comments_page(uuid, timestamptz, int);
