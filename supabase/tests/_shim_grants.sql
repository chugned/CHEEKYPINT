-- Table-level grants that Supabase normally applies out of band. RLS still governs which
-- rows are visible; these just let `authenticated` attempt DML at all.
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
