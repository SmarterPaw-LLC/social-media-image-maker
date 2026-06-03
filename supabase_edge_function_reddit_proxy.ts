// ============================================================================
// SmarterPaw Social Image Tool — Reddit proxy Edge Function (v199+)
// Deploy this to Supabase → Edge Functions, name it: reddit-proxy
// ============================================================================
// Why this exists:
//   Reddit's public .json endpoints (reddit.com/r/*.json) returned 403 to all
//   browser-style requests in mid-2023 as part of their anti-scraping crackdown.
//   No free CORS proxy can fix that — they hit the same 403. The fix is to make
//   the request server-side with a real, identifiable User-Agent that Reddit
//   accepts (their TOS explicitly allows non-OAuth reads if you identify
//   yourself this way). This Edge Function does exactly that and forwards the
//   JSON back to the browser with CORS headers.
//
// How to deploy (no CLI required):
//   1. Supabase Dashboard → your project (ttyxodttyeykjijffgql)
//   2. Sidebar → Edge Functions
//   3. "Deploy a new function" → Name: reddit-proxy
//   4. Paste the entire contents of THIS FILE (everything below) into the editor
//   5. Click Deploy. Wait ~30s for the build to finish.
//   6. (No environment variables or secrets needed — this function holds no keys.)
//
// The client (index.html) calls this via sb.functions.invoke('reddit-proxy',
// { body: { sub, t, limit } }) — auth is automatic since the app requires
// sign-in, and Edge Functions verify the JWT by default.
//
// Body parameters (all optional, all sanitized server-side):
//   sub   — subreddit name (alphanumeric + underscore, max 50 chars; default 'petmemes')
//   t     — timeframe: hour|day|week|month|year|all (default 'week')
//   limit — post count: 1..100 (default 50)
//
// Returns:
//   The raw Reddit JSON listing response, untouched. The client's existing
//   parsing logic (data.children → filter to image posts → render tiles)
//   doesn't care that this came through a proxy.
// ============================================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";

// Reddit's API docs ask for a unique, descriptive User-Agent. Generic UAs get
// throttled or 403'd; this one identifies the app and brand cleanly.
const REDDIT_USER_AGENT = "web:smarterpaw-design-tool:1.0 (by SmarterPaw LLC)";

// Whitelist for Reddit's `t` (timeframe) parameter so a malformed/malicious
// value can't be forwarded to Reddit.
const VALID_TIMES = new Set(["hour", "day", "week", "month", "year", "all"]);

// Standard CORS headers — the function is called from the browser app, which is
// served from a different origin than supabase.co.
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  // Preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    // Parse + sanitize the body. Default values let the client omit any param.
    const body = await req.json().catch(() => ({} as Record<string, unknown>));

    const subRaw = String((body as any).sub ?? "petmemes");
    // Subreddit names: alphanumeric + underscore only, 50-char cap. Strips any
    // injection-y characters in case the client sends something unexpected.
    const sub = subRaw.replace(/[^a-zA-Z0-9_]/g, "").slice(0, 50) || "petmemes";

    const tRaw = String((body as any).t ?? "week");
    const t = VALID_TIMES.has(tRaw) ? tRaw : "week";

    const limitNum = parseInt(String((body as any).limit ?? "50"), 10);
    const limit = Math.max(1, Math.min(100, isNaN(limitNum) ? 50 : limitNum));

    // raw_json=1 tells Reddit to send unescaped JSON (no &amp; etc.)
    const redditUrl =
      `https://www.reddit.com/r/${sub}/top.json?t=${t}&limit=${limit}&raw_json=1`;

    const upstream = await fetch(redditUrl, {
      headers: {
        "User-Agent": REDDIT_USER_AGENT,
        "Accept": "application/json",
      },
    });

    if (!upstream.ok) {
      // Forward Reddit's error so the client can show a meaningful message
      // (404 for non-existent subreddit, 429 if Reddit rate-limits, etc.)
      const text = await upstream.text().catch(() => "");
      return new Response(
        JSON.stringify({
          error: `Reddit returned ${upstream.status}`,
          details: text.slice(0, 300),
        }),
        {
          status: upstream.status,
          headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
        },
      );
    }

    // Pass through the JSON body verbatim. Cache 5 min at the edge so quick
    // tab-switching back to the same view doesn't re-hit Reddit.
    const data = await upstream.text();
    return new Response(data, {
      headers: {
        ...CORS_HEADERS,
        "Content-Type": "application/json",
        "Cache-Control": "public, max-age=300",
      },
    });
  } catch (e) {
    return new Response(
      JSON.stringify({ error: String((e as Error)?.message || e) }),
      {
        status: 500,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      },
    );
  }
});
