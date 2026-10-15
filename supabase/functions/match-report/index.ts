// The Scratch Sheet — "match-report" Edge Function.
// Writes a locked match's headline, summary, highlights and lowlights with Claude and saves them
// to public.match_reports. The Anthropic key lives only here, as the ANTHROPIC_API_KEY secret.
//
// Deploy: Supabase → Edge Functions → Deploy a new function → Via Editor → name it match-report,
// paste this file, Deploy. Then turn OFF "Verify JWT with legacy secret" in its settings
// (this function checks the caller itself). Add the secret ANTHROPIC_API_KEY under Edge Functions → Secrets.

import { createClient } from "npm:@supabase/supabase-js@2.110.9";

const MODEL = Deno.env.get("REPORT_MODEL") || "claude-haiku-5-5";
const MAX_WRITES_PER_MATCH = 6;   // first write + a few rewrites; protects the API bill

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const SYSTEM = `You write the match report for a recreational 8-ball doubles pool league team. The card is shared in the team's group chat, and the team is mostly gay men, so write for them: the voice of the funniest, shadiest friend at the gay bar doing play-by-play.

Voice
- Campy, sassy, warm, quick. Think drag-brunch host meets sports desk. Terms of endearment ("honey", "darling", "queens", "the girls") and a little diva drama are welcome.
- Pool is full of double entendres (balls, sticks, racks, pockets, strokes, tips, "sinking it", "going deep", "on the rail", "bending over the table") and you may lean into them with a wink.
- Innuendo stays suggestive and playful, never explicit: no sex acts, no anatomy, no crude or vulgar words, no profanity. If a line would make a bartender blush rather than laugh, cut it.
- Tease the play, never the person: no jokes about bodies, looks, age, race, religion, HIV or anyone's identity; no slurs, including reclaimed ones. Shade about a scratch is fine; cruelty isn't. The losing side and the opponent get a playful nod, not mockery.
- Celebrate wins big, take losses with style and a little defiance.

Facts
- Use only the facts given. Never invent players, scores, shots, comebacks, quotes, streaks or numbers. Every name and number you write must appear in the facts.
- Player names are written exactly as given. Game numbers, records and scratch counts must match the facts.
- If a fact isn't there, leave it out rather than guess.

Output
Reply with one JSON object and nothing else:
{"headline": string, "summary": string, "highs": string[], "lows": string[]}
- headline: at most 44 characters, punchy, no trailing period. It is printed in tall capital letters.
- summary: 2 or 3 sentences, at most 250 characters in total. Tell the story of the night and work in the season trend.
- highs: rewrite each item in facts.highlights in your voice, same order, same count, each at most 80 characters. If there are none, return [].
- lows: rewrite each item in facts.lowlights the same way. Keep the first one's player name and scratch count exactly. If there are none, return [].
- Plain text only: no emoji, no hashtags, no markdown, no quotation marks around the whole string.`;

function count(games: any[]) {
  let w = 0, l = 0;
  for (const g of games || []) { if (g?.result === "W") w++; else if (g?.result === "L" || g?.result === "FF") l++; }
  return { w, l };
}
const str = (v: unknown, max: number) => typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) : "";
const list = (v: unknown, max: number) => Array.isArray(v) ? v.map(x => str(x, max)).filter(Boolean).slice(0, 2) : [];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  try {
    const KEY = Deno.env.get("ANTHROPIC_API_KEY");
    if (!KEY) return json({ error: "The ANTHROPIC_API_KEY secret isn't set." }, 500);
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const auth = req.headers.get("Authorization") || "";
    const jwt = auth.replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "Sign in first." }, 401);

    // who's calling, and can they see this match? (row-level security decides)
    const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: u, error: ue } = await asUser.auth.getUser(jwt);
    if (ue || !u?.user) return json({ error: "Your session ended. Sign in again." }, 401);

    const body = await req.json().catch(() => ({}));
    const matchId = String(body.matchId || ""), force = !!body.force, facts = body.facts || {};
    if (!/^[A-Za-z0-9_-]{4,64}$/.test(matchId)) return json({ error: "Bad match id." }, 400);
    const { data: row } = await asUser.from("matches").select("id,team_id,data").eq("id", matchId).maybeSingle();
    if (!row) return json({ error: "Match not found." }, 404);
    const m = row.data || {};
    if (!m.locked) return json({ error: "Lock the match first." }, 409);

    // the facts must describe this match as it's saved
    const sc = count(m.games);
    if (facts.lockedAt !== m.lockedAt || facts.score?.us !== sc.w || facts.score?.them !== sc.l)
      return json({ error: "The match changed. Reopen the report." }, 409);

    const admin = createClient(url, service, { auth: { persistSession: false } });
    const { data: prev } = await admin.from("match_reports").select("*").eq("match_id", matchId).maybeSingle();
    if (prev && prev.locked_at === m.lockedAt && !force) return json({ report: prev });
    if (prev && prev.gen_count >= MAX_WRITES_PER_MATCH) return json({ report: prev, error: "This report has been rewritten as many times as it can be." }, 429);

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 700, temperature: 1,
        system: SYSTEM,
        messages: [{ role: "user", content: `Facts for tonight's match report:\n${JSON.stringify(facts)}` }],
      }),
    });
    if (!res.ok) {
      const t = await res.text();
      console.error("anthropic", res.status, t.slice(0, 500));
      return json({ error: "Claude couldn't write the report right now." }, 502);
    }
    const out = await res.json();
    const text = (out.content || []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("");
    const raw = text.match(/\{[\s\S]*\}/)?.[0];
    let ai: any; try { ai = JSON.parse(raw || ""); } catch { return json({ error: "Claude's reply wasn't usable." }, 502); }

    const want = (k: string) => Array.isArray(facts[k]) ? facts[k].length : 0;
    const highs = list(ai.highs, 100), lows = list(ai.lows, 100);
    const data = {
      headline: str(ai.headline, 56).replace(/[.!]+$/, ""),
      summary: str(ai.summary, 320),
      highs: highs.length === Math.min(2, want("highlights")) ? highs : null,   // null → the app keeps its own lines
      lows: lows.length === Math.min(2, want("lowlights")) ? lows : null,
    };
    if (!data.headline || !data.summary) return json({ error: "Claude's reply was missing pieces." }, 502);

    const rec = { match_id: matchId, team_id: row.team_id, locked_at: m.lockedAt, data, model: MODEL, gen_count: (prev?.gen_count || 0) + 1, updated_at: new Date().toISOString() };
    const { error: we } = await admin.from("match_reports").upsert(rec);
    if (we) { console.error("save", we); return json({ error: "Couldn't save the report." }, 500); }
    return json({ report: rec });
  } catch (e) {
    console.error(e);
    return json({ error: "Something went wrong writing the report." }, 500);
  }
});
