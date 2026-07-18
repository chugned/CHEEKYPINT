// Shared CORS headers for CheekyPint Edge Functions. The app calls these from a native
// client, but permissive CORS keeps local tooling and the Studio "invoke" panel working.
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
