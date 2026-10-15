// The Scratch Sheet — "match-report" Edge Function.
// Writes a locked match's headline, summary, highlights and lowlights with Claude and saves them
// to public.match_reports. The Anthropic key lives only here, as the ANTHROPIC_API_KEY secret.
//
// Deploy: Supabase → Edge Functions → Deploy a new function → Via Editor → name it match-report,
// paste this file, Deploy. Then turn OFF "Verify JWT with legacy secret" in its settings
// (this function checks the caller itself). Add the secret ANTHROPIC_API_KEY under Edge Functions → Secrets.

import { createClient } from "npm:@supabase/supabase-js@2.110.9";

const MODEL = Deno.env.get("REPORT_MODEL") || "claude-haiku-5-5";
const MAX_WRITES_PER_MATCH = 10;   // first write + a few rewrites; protects the API bill

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Comic sensibilities to channel, one picked at random per write-up. Style only: the write-up never
// names the person, quotes them, or uses their catchphrases or characters' lines.
const VOICES: [string, string][] = [
  ["Brian Gallivan", "brisk best-friend intervention: quick rhetorical questions, affectionate scolding, a wake-up-call tone"],
  ["Louis Virtel", "pop-culture savant: precise, erudite word choice, dry superlatives, trivia-sharp comparisons"],
  ["Bowen Yang", "deadpan absurdism: oddly specific details delivered with a straight face, earnest about silly things"],
  ["Matteo Lane", "warm observational storyteller: a touch of opera-house drama, playful self-deprecation"],
  ["Billy Eichner", "breathless, high-energy game-show host: rapid enthusiasm, mock outrage, quiz-show urgency"],
  ["Jerrod Carmichael", "quiet and candid: unhurried, plainspoken observations that land harder than jokes"],
  ["Graham Norton", "cheerful talk-show host: chatty warmth, gleeful gossip, delighted asides"],
  ["Billy Porter", "grand and theatrical: fashion and runway metaphors, regal pronouncements"],
  ["Dan Levy", "dry, fastidious exasperation: withering understatement, polite horror at sloppiness"],
  ["Lil Nas X", "extremely online: playful trolling, confident, meme-literate brevity"],
  ["Dolly Parton", "Southern warmth: folksy one-liners, big heart, gentle self-deprecating wit"],
  ["Bette Midler", "brassy old-school showbiz: big-stage flair, wisecracking diva warmth"],
  ["Catherine O'Hara", "eccentric grandeur: unusual, ornate vocabulary and theatrical oddball phrasing"],
  ["Jennifer Coolidge", "dreamy and breathy: meandering non sequiturs that stumble into accidental wisdom"],
  ["Liza Minnelli", "razzle-dazzle cabaret: show-must-go-on spirit, jazz-hands exclamations"],
  ["Ziwe", "pointed interviewer: direct, slightly uncomfortable questions put to the scoresheet"],
  ["Wanda Sykes", "incredulous side-eye: dry disbelief, unimpressed and very funny about it"],
  ["Kathy Griffin", "gossipy insider: dishy asides about who did what, cheerful self-deprecation"],
  ["Joan Rivers", "rapid-fire one-liners: red-carpet critique aimed squarely at the shots, not the people"],
  ["Chelsea Handler", "blunt and unbothered: candid, cocktail-in-hand straight talk"],
  ["Margaret Cho", "bold and irreverent with big-sister warmth: frank, generous, loud in the best way"],
  ["Nikki Glaser", "sharp roast precision softened by a self-aware wince"],
  ["Natasha Lyonne", "raspy streetwise New York: hard-boiled detective narrating the case"],
  ["Tig Notaro", "ultra-deadpan understatement: short sentences, long pauses, quiet absurdity"],
  ["Trixie Mattel", "drag-queen quips with a retro-Barbie, country-camp twist and groan-worthy puns"],
  ["RuPaul", "pageant emcee: encouraging, runway-call wordplay, pep talk with polish"],
  ["Aubrey Plaza", "dead-eyed and disinterested: dry sarcasm with an unsettling calm"],
  ["John Mulaney", "precise storyteller: polite cadence, elaborate analogies, fussy specifics"],
  ["Titus Andromedon", "melodramatic Broadway hopeful: outsized reactions, every win a starring role"],
];

const SYSTEM = `You write the match report for a recreational 8-ball doubles pool league team. The card is shared in the team's group chat. The team is mostly gay men, and the humor is written for them: knowing, witty, a little camp.

Tone
- Personality first. The voice should be unmistakable in every part: the headline has attitude, the summary reads like a person with opinions telling the story, and each highlight and lowlight carries a little flavor. Not every clause needs a punchline, but nothing should read like a box score.
- Avoid flat sports-wire phrasing: "secured a victory", "solid performance", "came out on top", "a hard-fought battle", "showed resilience".
- Camp and sass are welcome in moderation: up to two terms of endearment or diva flourishes per report when the voice suits them, never the same one twice. Don't lean on the same stock words every time ("honey", "darling", "the girls", "queens", "clutching pearls", "serving", "slay", "yas"); find fresher ways to say it.
- One or two pool double entendres (racks, strokes, sinking it, pockets, going deep, balls in hand) are welcome when they land naturally. Suggestive and winking, never explicit: no sex acts, no anatomy, no crude or vulgar words, no profanity.
- Tease the play, never the person: no jokes about bodies, looks, age, race, religion, HIV or anyone's identity; no slurs, including reclaimed ones. Shade about a scratch is fine; cruelty isn't. The opponent gets a nod, not mockery.
- Vary the shape: don't open every sentence the same way, and don't start the summary with the score.

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

const voiceNote = ([name, style]: [string, string]) => `

Voice for this report
Channel the comic sensibility of ${name}: ${style}. Commit to it: their rhythm, attitude and comic instincts should shape every line, so each report sounds clearly different from the last. Do not name ${name}, quote them, or use their catchphrases, signature bits or references to their shows; write original lines in that spirit.`;

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

    const { data: recent } = await admin.from("match_reports").select("data").eq("team_id", row.team_id).order("updated_at", { ascending: false }).limit(8);
    const used = new Set((recent || []).map((r: any) => r.data?.voice).concat(prev?.data?.voice));
    const pool = VOICES.filter(v => !used.has(v[0]));
    const voice = (pool.length ? pool : VOICES)[Math.floor(Math.random() * (pool.length || VOICES.length))];

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 2000,
        system: SYSTEM + voiceNote(voice),
        messages: [{ role: "user", content: `Facts for tonight's match report:\n${JSON.stringify(facts)}` }],
      }),
    });
    if (!res.ok) {
      const t = await res.text();
      console.error("anthropic", res.status, t.slice(0, 800));
      let msg = t.slice(0, 200); try { msg = JSON.parse(t)?.error?.message || msg; } catch { /* plain text */ }
      return json({ error: `Anthropic API ${res.status}: ${msg}` }, 502);
    }
    const out = await res.json();
    const text = (out.content || []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("");
    const clean = text.replace(/```(?:json)?/gi, "");
    const a = clean.indexOf("{"), b = clean.lastIndexOf("}");
    let ai: any; try { ai = JSON.parse(clean.slice(a, b + 1)); } catch {
      console.error("unparsed reply", out.stop_reason, JSON.stringify(out.content).slice(0, 1500));
      return json({ error: `Claude's reply wasn't readable (stop: ${out.stop_reason}).` }, 502);
    }

    const want = (k: string) => Array.isArray(facts[k]) ? facts[k].length : 0;
    const highs = list(ai.highs, 100), lows = list(ai.lows, 100);
    const data = {
      headline: str(ai.headline, 56).replace(/[.!]+$/, ""),
      summary: str(ai.summary, 320),
      highs: highs.length === Math.min(2, want("highlights")) ? highs : null,   // null → the app keeps its own lines
      lows: lows.length === Math.min(2, want("lowlights")) ? lows : null,
      voice: voice[0],
    };
    if (!data.headline || !data.summary) { console.error("missing pieces", text.slice(0, 1500)); return json({ error: "Claude's reply was missing the headline or summary." }, 502); }

    const rec = { match_id: matchId, team_id: row.team_id, locked_at: m.lockedAt, data, model: MODEL, gen_count: (prev?.gen_count || 0) + 1, updated_at: new Date().toISOString() };
    const { error: we } = await admin.from("match_reports").upsert(rec);
    if (we) { console.error("save", we); return json({ error: "Couldn't save the report." }, 500); }
    return json({ report: rec });
  } catch (e) {
    console.error(e);
    return json({ error: `Something went wrong writing the report: ${(e as Error)?.message || e}` }, 500);
  }
});
