-- Feed posts carry photos, and 'inappropriate_profile_image' would mislead a moderator triaging
-- the queue. This value is added in its own migration because a new enum value cannot be
-- referenced by other statements in the transaction that creates it.
alter type public.report_category add value if not exists 'inappropriate_post_image';
