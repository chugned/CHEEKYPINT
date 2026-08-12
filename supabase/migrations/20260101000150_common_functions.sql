-- CheekyPint schema — 01b. Common functions
--
-- Shared trigger + tiny helpers used across later migrations. Kept SECURITY INVOKER and
-- with a locked search_path.

-- Touch `updated_at` on every UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at is
  'Trigger function that stamps updated_at = now() on row updates.';

-- Shared sanitiser for user-supplied text. Deletes C0/C1 control characters plus the
-- zero-width and bidi-override characters used to spoof or scramble displayed text.
--
-- Lives here, not with the feed tables that first needed it, because it is also called by
-- public.report_user (20260101000800_rpc_social.sql) — every RPC that writes free text a human
-- later reads goes through it, and those RPCs are spread across migrations from 000800 onwards.
-- A helper referenced by an earlier migration than the one defining it only works by accident
-- (plpgsql bodies are not name-resolved at CREATE time); declaring it up front makes the
-- dependency real.
create or replace function public.strip_ugc_control_chars(t text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           translate(
             coalesce(t, ''),
             chr(8203) || chr(8204) || chr(8205) || chr(8206) || chr(8207) ||
             chr(8234) || chr(8235) || chr(8236) || chr(8237) || chr(8238) || chr(65279) ||
             chr(8288) || chr(8294) || chr(8295) || chr(8296) || chr(8297),
             ''
           ),
           '[[:cntrl:]]', '', 'g'
         );
$$;

comment on function public.strip_ugc_control_chars(text) is
  'Strips control, zero-width and bidi characters from user-supplied text.';

revoke all on function public.strip_ugc_control_chars(text) from public, anon;
grant execute on function public.strip_ugc_control_chars(text) to authenticated;

-- Newline-preserving sibling, for the columns whose composer accepts line breaks and whose display
-- shows them. `[[:cntrl:]]` covers characters 0–31, so the function above deletes chr(10) and
-- chr(13) along with every other control character — which silently flattened multi-line post
-- bodies, comments and report details on the way in. The client already models this distinction
-- (`ProfileTextSanitizer.sanitize(_:allowNewlines:maxLength:)`); this is the server half of it.
--
-- Deliberately a second function rather than a flag on the first: single-line columns
-- (posts.place_label, pub_sessions.name) genuinely should have newlines removed, and changing shared
-- behaviour under every existing caller is the mistake this project already made once.
--
-- It works by splitting on the line separators and running the single-line stripper over each line,
-- so the control/zero-width/bidi sets have exactly ONE definition and the two functions can never
-- drift apart.
--
--   1. CRLF and a lone CR both normalise to LF first, so a Windows or on-screen-keyboard paste is
--      one break rather than two (or, once stripped, none).
--   2. Every other control character still goes, per line.
--   3. Runs of blank lines collapse to at most one — three or more consecutive LFs become two.
--      That matches ProfileTextSanitizer.collapseBlankLines exactly, keeps ordinary paragraph
--      breaks intact, and stops a body of 400 newlines being used as a layout weapon in the feed.
--   4. Leading and trailing spaces/newlines are trimmed here (the single-line callers do this with
--      their own btrim, which trims spaces only and would leave a leading blank line behind), so
--      callers need only `nullif(..., '')` to reject a whitespace-only body.
--
-- The surviving newlines COUNT against each caller's `left(..., n)` bound, because they are
-- characters in the string like any other — which is what the client's counters already assume
-- (`sanitizedLength(_:allowNewlines: true)` counts them too).
create or replace function public.strip_ugc_control_chars_multiline(t text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(
           regexp_replace(
             (
               select coalesce(string_agg(public.strip_ugc_control_chars(line), chr(10) order by ord), '')
                 from regexp_split_to_table(
                        regexp_replace(coalesce(t, ''), chr(13) || chr(10) || '?', chr(10), 'g'),
                        chr(10)
                      ) with ordinality as lines(line, ord)
             ),
             chr(10) || '{3,}', chr(10) || chr(10), 'g'
           ),
           ' ' || chr(10)
         );
$$;

comment on function public.strip_ugc_control_chars_multiline(text) is
  'Strips control, zero-width and bidi characters from user-supplied text but keeps line breaks: '
  'CRLF/CR normalise to LF, blank-line runs collapse to one, ends are trimmed.';

revoke all on function public.strip_ugc_control_chars_multiline(text) from public, anon;
grant execute on function public.strip_ugc_control_chars_multiline(text) to authenticated;
