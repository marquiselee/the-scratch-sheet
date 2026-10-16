// The Scratch Sheet — "match-report" Edge Function.
// Writes a locked match's headline, summary, highlights and lowlights with Claude and saves them
// to public.match_reports. The Anthropic key lives only here, as the ANTHROPIC_API_KEY secret.
//
// Deploy: Supabase → Edge Functions → Deploy a new function → Via Editor → name it match-report,
// paste this file, Deploy. Then turn OFF "Verify JWT with legacy secret" in its settings
// (this function checks the caller itself). Add the secret ANTHROPIC_API_KEY under Edge Functions → Secrets.

import { createClient } from "npm:@supabase/supabase-js@2.110.9";

const MODEL = Deno.env.get("REPORT_MODEL") || "claude-haiku-5-5";
const MAX_WRITES_PER_MATCH = 10;   // for team admins; owners and league admins have no limit
// one optional web search per write-up for something current to joke about (about $0.01 each); set REPORT_WEB_SEARCH=off to disable
const SEARCH = (Deno.env.get("REPORT_WEB_SEARCH") || "on") !== "off";
const SEARCH_TOOL = Deno.env.get("REPORT_SEARCH_TOOL") || "web_search_20250305";   // first write + a few rewrites; protects the API bill

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
- Criticism and roast-style humor about how people played are fine: a missed hanger, a scratch-fest, a bad safety, a sulky loss. What's never fine: attacking, disparaging, mocking, or promoting hatred or exclusion of anyone based on race, ethnicity, religion, gender, gender identity, sexual orientation, age, disability or national origin. No jokes about bodies or looks, and no slurs, including reclaimed ones.
- Nothing vulgar or offensive, even if a team comment is. Never repeat crude language from a comment; paraphrase it clean or leave it out.
- Vary the shape: don't open every sentence the same way, and don't start the summary with the score.

Finding the story
- facts.storylines lists what made this match distinctive, most notable first: the margin (sweep, blowout, nail-biter), how it was decided (game 5, an early clinch the opponent made look close, an 8-ball scratch that swung a game or the match), attendance and subs, who carried the team or went cold, streaks, the history with this opponent (revenge, payback, a repeat), and the two team names.
- facts.comments are notes the team wrote during the match. Read them for tone (triumphant, frustrated, rowdy, petty, proud) and for notable moments: great shots, run-outs, bank shots, safety battles, fouls, disputes, bar happenings. A vivid comment is often the best material on the card; build on it rather than repeating it word for word. When a comment has an author ("by"), you may credit them ("according to Kwame"); the author isn't necessarily the player in that game.
- Choose the angle from the storylines and comments, favoring whatever is most specific to this match and different from facts.recentReports. Good angles include: a blowout told as a massacre or a coronation; a game-5 heart-stopper; "clinched in three, then got lazy"; a match lost on the 8; a skeleton crew that showed up anyway; one player carrying everyone; a revenge match; a streak building or snapping; a team that did or didn't live up to its name (Sharks without teeth, Hustlers who got hustled).
- Scratches are the angle only when they decided the result or were truly extreme. Otherwise mention them in passing, if at all; the lowlights already cover them.

One idea per report
- Before writing, pick one angle from the story above. Write it in "angle".
- The headline states that angle. It sets the tone and the theme for the whole card.
- The summary pays off the headline: it develops the same idea, its jokes and any reference grow out of the headline's premise, and the last line lands a callback or twist on it. A reader should feel the headline and summary were written as one bit.
- Highlights and lowlights keep the same voice and can wink at the theme, but their facts come first.

Making the summary funny
- The jokes are about this match. Start from what actually happened: who paired with whom, the comeback or the collapse, the clincher, the scratch that cost a game, the streak, the sweep, the player who couldn't miss or couldn't stop scratching. Find the funny in those specifics.
- Use the full toolkit on those specifics: puns (including on the opponent's team name), double entendres, innuendo, oxymorons, malapropisms, spoonerisms, hyperbole, irony, understatement, mock-epic framing.
- An outside reference (film, TV, music, history, art, literature, a sports moment, something local or current) is allowed only when it maps onto a specific moment of the match. A comeback can earn a famous comeback; three scratches can earn a famous disaster; a pair who can't lose can earn a famous duo. A reference that only matches the city, the date or the weather, and not the match, is filler: cut it. Test: if the line would work just as well for any other match, rewrite it.
- At most one outside reference per report, and plenty of reports should have none.
- facts.context, when present, is background, not material. Mention the city, the weather or the date only if it sharpens a joke about the match itself, which should be rare.
- facts.recentReports are this team's last few write-ups. Don't repeat their references, jokes, puns, openings or sentence shapes.
- Keep references light and affectionate. No politics, tragedies, disasters, crime, illness or deaths, even if they're in the news.
- Don't present anything as recent news unless it came from your search. The jokes can be invented; the facts about the match and the world can't.

Facts
- Use only the facts given. Never invent players, scores, shots, comebacks, quotes, streaks or numbers. Every name and number you write must appear in the facts.
- Player names are written exactly as given. Game numbers, records and scratch counts must match the facts.
- If a fact isn't there, leave it out rather than guess.

Output
Reply with one JSON object and nothing else:
{"angle": string, "headline": string, "summary": string, "highs": string[], "lows": string[]}
- angle: one short sentence naming the comic idea. It isn't shown on the card.
- headline: at most 44 characters, punchy, no trailing period. It is printed in tall capital letters.
- summary: 2 or 3 sentences, at most 250 characters in total. Tell the story of the night and work in the season trend. This is the funniest part of the card (see "Making the summary funny").
- highs and lows: up to 2 each, each at most 80 characters, written in this report's voice. Draw from three sources: the scoresheet lines in facts.highlights and facts.lowlights; everything in facts.comments (game and match notes, tagged or not; a tag is the writer's hint, not a requirement); and your own observations from facts.storylines, facts.games and facts.players (a clutch game-5 pair, a player who went unbeaten, a comeback, a revenge win, a perfect night spoiled, a scratch on the 8 that cost a game, a skeleton crew that held on).
  - Keep only items that are relevant to the match and substantive: a great or awful shot, a run-out, a clutch game, a costly scratch, a dispute, a turning point, a standout or struggling player, how the team felt about the night. Skip filler and logistics ("late start", "poutine after", "table 3 is crooked") unless it genuinely shaped the match.
  - Paraphrase in your voice to capture each comment's sentiment and the facts in it; don't copy it word for word. You may credit the author.
  - If facts.mustLowlight is present, it must be the first lowlight: rephrase it, but keep the player's name and scratch count exactly.
  - Your own highlights and lowlights are welcome, especially when there are few or no comments. They must rest on facts you were given, stay relevant to this match, and be fun to read: give each one the voice's attitude, not a box-score restatement.
  - Usually fill both slots of each. Return fewer only when the match truly offers less (a forfeit, say); a sweep may have no real lowlight, and a shutout loss may have only a defiant highlight.
- Plain text only: no emoji, no hashtags, no markdown, no quotation marks around the whole string.`;

const voiceNote = ([name, style]: [string, string]) => `

Voice for this report
Channel the comic sensibility of ${name}: ${style}. Commit to it: their rhythm, attitude and comic instincts should shape every line, so each report sounds clearly different from the last. Do not name ${name}, quote them, or use their catchphrases, signature bits or references to their shows; write original lines in that spirit.`;

const STATES: Record<string, string> = { AL: "Alabama", AK: "Alaska", AZ: "Arizona", AR: "Arkansas", CA: "California", CO: "Colorado", CT: "Connecticut", DE: "Delaware", DC: "District of Columbia", FL: "Florida", GA: "Georgia", HI: "Hawaii", ID: "Idaho", IL: "Illinois", IN: "Indiana", IA: "Iowa", KS: "Kansas", KY: "Kentucky", LA: "Louisiana", ME: "Maine", MD: "Maryland", MA: "Massachusetts", MI: "Michigan", MN: "Minnesota", MS: "Mississippi", MO: "Missouri", MT: "Montana", NE: "Nebraska", NV: "Nevada", NH: "New Hampshire", NJ: "New Jersey", NM: "New Mexico", NY: "New York", NC: "North Carolina", ND: "North Dakota", OH: "Ohio", OK: "Oklahoma", OR: "Oregon", PA: "Pennsylvania", RI: "Rhode Island", SC: "South Carolina", SD: "South Dakota", TN: "Tennessee", TX: "Texas", UT: "Utah", VT: "Vermont", VA: "Virginia", WA: "Washington", WV: "West Virginia", WI: "Wisconsin", WY: "Wyoming" };
const WX: [number, string][] = [[0, "clear skies"], [1, "mostly clear"], [2, "partly cloudy"], [3, "overcast"], [48, "foggy"], [57, "drizzly"], [67, "rainy"], [77, "snowy"], [82, "rain showers"], [86, "snow showers"], [99, "thunderstorms"]];
const wxText = (c: number) => (WX.find(([max]) => c <= max) || [0, ""])[1];

async function getJSON(u: string) {
  const r = await fetch(u, { signal: AbortSignal.timeout(4000) });
  if (!r.ok) throw new Error(String(r.status));
  return r.json();
}
// "Philadelphia, PA" → place + that day's weather from Open-Meteo (free, no key). Best effort: null on any trouble.
async function placeAndWeather(city: string, date: string) {
  try {
    const [name, region = ""] = city.split(",").map(x => x.trim());
    if (!name) return null;
    const g = await getJSON(`https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(name)}&count=10&language=en`);
    const want = (STATES[region.toUpperCase()] || region).toLowerCase();
    const res: any[] = g.results || [];
    const hit = res.find(x => want && [x.admin1, x.country, x.country_code].some((v: string) => (v || "").toLowerCase() === want))
      || res.find(x => x.country_code === "US") || res[0];
    if (!hit) return null;
    const place = { city: hit.name, region: hit.admin1 || "", country: hit.country_code || "", timezone: hit.timezone || "" };
    let weather = null;
    if (/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      const q = `latitude=${hit.latitude}&longitude=${hit.longitude}&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum&temperature_unit=fahrenheit&precipitation_unit=inch&timezone=auto&start_date=${date}&end_date=${date}`;
      const w = await getJSON(`https://api.open-meteo.com/v1/forecast?${q}`).catch(() => getJSON(`https://archive-api.open-meteo.com/v1/archive?${q}`));
      const d = w?.daily;
      if (d?.temperature_2m_max?.[0] != null)
        weather = `${wxText(d.weather_code?.[0] ?? 0)}, high ${Math.round(d.temperature_2m_max[0])}°F, low ${Math.round(d.temperature_2m_min[0])}°F${d.precipitation_sum?.[0] > 0.05 ? `, ${d.precipitation_sum[0].toFixed(1)} in of precipitation` : ""}`;
    }
    return { place, weather };
  } catch { return null; }
}

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
    // owners and this league's admins can rewrite without limit; everyone else is capped
    const [{ data: who }, { data: tm }] = await Promise.all([
      admin.from("admins").select("role,league_id").eq("user_id", u.user.id).maybeSingle(),
      admin.from("teams").select("league_id").eq("id", row.team_id).maybeSingle(),
    ]);
    const unlimited = who?.role === "owner" || (who?.role === "league" && who.league_id === tm?.league_id);
    if (!unlimited && prev && prev.gen_count >= MAX_WRITES_PER_MATCH) return json({ report: prev, error: "This report has been rewritten as many times as it can be." }, 429);

    const { data: recent } = await admin.from("match_reports").select("data").eq("team_id", row.team_id).order("updated_at", { ascending: false }).limit(8);
    const used = new Set((recent || []).map((r: any) => r.data?.voice).concat(prev?.data?.voice));
    const pool = VOICES.filter(v => !used.has(v[0]));
    const voice = (pool.length ? pool : VOICES)[Math.floor(Math.random() * (pool.length || VOICES.length))];

    // setting: the day, the city and that day's weather
    const city = str(facts.city, 80);
    const pw = city ? await placeAndWeather(city, String(facts.date || "")) : null;
    const day = /^\d{4}-\d{2}-\d{2}$/.test(facts.date || "") ? new Date(facts.date + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "UTC" }) : "";
    // background only, and not every time, so the setting doesn't creep into every summary
    const context = { matchDay: day || undefined, city: pw?.place ? [pw.place.city, pw.place.region].filter(Boolean).join(", ") : city || undefined, weatherThatDay: Math.random() < 0.3 ? pw?.weather || undefined : undefined };
    const recentReports = (recent || []).filter((r: any) => r.data?.summary).slice(0, 5).map((r: any) => ({ headline: r.data.headline, summary: r.data.summary }));
    const { city: _c, ...matchFacts } = facts;
    const searchHint = SEARCH ? `\n\nOptional: if one moment of this match (a comeback, a collapse, a streak, a scratch-fest, a clutch finish) reminds you of something that might be in the news around ${day || "the match day"}${context.city ? ` or around ${context.city}` : ""}, you may run one web search to check it. Use it only if it fits that moment. Most reports won't need a search. Skip anything political or grim.` : "";
    const ask = (withSearch: boolean) => fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 3000,
        system: SYSTEM + voiceNote(voice),
        messages: [{ role: "user", content: `Facts for tonight's match report:\n${JSON.stringify({ ...matchFacts, context, recentReports })}${withSearch ? searchHint : ""}\n\nReply with the JSON object only.` }],
        ...(withSearch ? { tools: [{ type: SEARCH_TOOL, name: "web_search", max_uses: 1, ...(pw?.place?.country ? { user_location: { type: "approximate", city: pw.place.city, region: pw.place.region, country: pw.place.country, timezone: pw.place.timezone || undefined } } : {}) }] } : {}),
      }),
    });
    let res = await ask(SEARCH);
    if (SEARCH && !res.ok && res.status === 400) {   // web search not enabled for this Anthropic account: write without it
      console.error("web search refused", (await res.text()).slice(0, 300));
      res = await ask(false);
    }
    if (!res.ok) {
      const t = await res.text();
      console.error("anthropic", res.status, t.slice(0, 800));
      let msg = t.slice(0, 200); try { msg = JSON.parse(t)?.error?.message || msg; } catch { /* plain text */ }
      return json({ error: `Anthropic API ${res.status}: ${msg}` }, 502);
    }
    const out = await res.json();
    const blocks: any[] = out.content || [];
    const lastTool = blocks.map(c => c.type).lastIndexOf("web_search_tool_result");   // the answer comes after any search
    const text = blocks.slice(lastTool + 1).filter(c => c.type === "text").map(c => c.text).join("");
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
      // Claude picks 0–2 of each; an empty pick when the scoresheet had something falls back to the app's own lines (null)
      highs: highs.length || !want("highlights") ? highs : null,
      lows: lows.length || !want("lowlights") ? lows : null,
      voice: voice[0],
      angle: str(ai.angle, 200) || undefined,
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
