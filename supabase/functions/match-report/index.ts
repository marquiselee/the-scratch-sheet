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

// Prompts live in the private ai_prompts table (see migration 013); only plain fallbacks are kept here.
const FALLBACK_VOICES: { name: string; style: string }[] = [{ name: "a witty sports columnist", style: "clear, lively and good-natured" }];
const FALLBACK_REPORT = `You write a short, fun match report for a recreational 8-ball doubles pool league team, shared in the team's group chat.
Use only the facts given; never invent players, scores or events. Keep it friendly and never vulgar or offensive.
Reply with one JSON object and nothing else:
{"angle": string, "headline": string, "summary": string, "highs": string[], "lows": string[]}
- headline: at most 44 characters, no trailing period.
- summary: 2 or 3 sentences, at most 250 characters.
- highs and lows: up to 2 each, each at most 80 characters, based on facts.highlights, facts.lowlights, facts.comments and facts.storylines. If facts.mustLowlight is present it must be the first lowlight with the player's name and scratch count kept exactly.
- Plain text only.`;
const FALLBACK_VOICE_NOTE = `\n\nWrite in the voice of {name}: {style}.`;
const FALLBACK_SCHEDULE = `Read the pool league schedule below (one spreadsheet row per line, cells as COLUMNROW=value) and reply with one JSON object only:
{"year": number, "venue": string|null, "games": [{"date": "YYYY-MM-DD", "time": "HH:MM" or null, "home": string, "away": string, "table": string or null, "week": string or null, "playoff": boolean, "round": string or null}]}
Copy team names exactly. Never invent matches.`;
let promptCache: { at: number; map: Record<string, string> } | null = null;
async function prompts(url: string, service: string) {
  if (promptCache && Date.now() - promptCache.at < 300000) return promptCache.map;
  const map: Record<string, string> = {};
  try {
    const admin = createClient(url, service, { auth: { persistSession: false } });
    const { data } = await admin.from("ai_prompts").select("key,body");
    (data || []).forEach((r: any) => { if (r.body) map[r.key] = r.body; });
  } catch (e) { console.error("prompts", e); }
  promptCache = { at: Date.now(), map };
  return map;
}
async function voicesList(url: string, service: string) {
  try { const v = JSON.parse((await prompts(url, service)).report_voices || "[]"); if (Array.isArray(v) && v.length && v.every((x: any) => x?.name && x?.style)) return v as { name: string; style: string }[]; } catch { /* fall back */ }
  return FALLBACK_VOICES;
}






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

// ---------- visits: one per device, team and day, with approximate location ----------
// Location is the US state for US visitors and only the country elsewhere. The IP address is used for
// the lookup and then discarded; it is never stored.
async function geoFor(req: Request) {
  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "";
  let country = (req.headers.get("cf-ipcountry") || "").toUpperCase(), region = "";
  const tryJson = async (u: string) => { try { const r = await fetch(u, { signal: AbortSignal.timeout(3000), headers: { "user-agent": "scratch-sheet" } }); return r.ok ? await r.json() : null; } catch { return null; } };
  if (ip && (!country || country === "US")) {
    const a = await tryJson(`https://ipapi.co/${encodeURIComponent(ip)}/json/`);
    if (a && !a.error && a.country_code) { country = String(a.country_code).toUpperCase(); region = a.region_code || ""; }
    else {
      const b = await tryJson(`https://ipwho.is/${encodeURIComponent(ip)}`);
      if (b && b.success !== false && b.country_code) { country = String(b.country_code).toUpperCase(); region = b.region_code || ""; }
    }
  }
  if (!/^[A-Z]{2}$/.test(country) || country === "XX" || country === "T1") return { country: null, region: null };
  return { country, region: country === "US" && /^[A-Z]{2}$/.test(region) ? region : null };
}
async function recordVisit(req: Request, body: any, asUser: any, url: string, service: string) {
  const device = String(body.device || ""), teamId = String(body.team || "");
  if (!/^[A-Za-z0-9-]{16,64}$/.test(device) || !/^[0-9a-f-]{36}$/i.test(teamId)) return json({ error: "Bad visit." }, 400);
  const { data: team } = await asUser.from("teams").select("id,league_id").eq("id", teamId).maybeSingle();   // row-level security: only teams the caller can open
  if (!team) return json({ error: "Team not found." }, 404);
  const admin = createClient(url, service, { auth: { persistSession: false } });
  const { data: u } = await asUser.auth.getUser();
  const { data: who } = u?.user ? await admin.from("admins").select("role").eq("user_id", u.user.id).maybeSingle() : { data: null };
  const role = who?.role || "member";
  const today = new Date().toISOString().slice(0, 10);
  const { error: de } = await admin.from("device_activity").insert({ device_id: device, day: today, team_id: team.id, league_id: team.league_id, role });
  if (de && de.code !== "23505") console.error("device_activity", de);
  if (de?.code === "23505") return json({ ok: true, repeat: true });   // already counted today
  const geo = await geoFor(req);
  const meta: Record<string, unknown> = {};
  if (["mobile", "tablet", "desktop"].includes(body.platform)) meta.platform = body.platform;
  if (/^(iOS|Android|Mac|Windows|Linux|ChromeOS|Other)$/.test(body.os || "")) meta.os = body.os;
  if (typeof body.standalone === "boolean") meta.standalone = body.standalone;
  const { error: ee } = await admin.from("events").insert({ type: "visit", league_id: team.league_id, team_id: team.id, device_id: device, role, meta, ...geo });
  if (ee) console.error("events", ee);
  await admin.rpc("stats_tick").then(() => {}, () => {});   // daily summaries + 100-day cleanup (no-op if already run today)
  return json({ ok: true });
}

// ---------- league schedule reading (fallback for layouts the app can't parse itself) ----------


async function readSchedule(body: any, uid: string, KEY: string, url: string, service: string) {
  const admin = createClient(url, service, { auth: { persistSession: false } });
  const { data: who } = await admin.from("admins").select("role,league_id").eq("user_id", uid).maybeSingle();
  if (!(who?.role === "owner" || (who?.role === "league" && who.league_id === body.league))) return json({ error: "Only an admin of this league can import its schedule." }, 403);
  const text = String(body.text || "").slice(0, 60000);
  if (!text.trim()) return json({ error: "The file looks empty." }, 400);
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 16000, system: (await prompts(url, service)).schedule_system || FALLBACK_SCHEDULE,
      messages: [{ role: "user", content: `File name: ${str(body.fileName, 200)}\nToday: ${new Date().toISOString().slice(0, 10)}\n\n${text}\n\nReply with the JSON object only.` }] }),
  });
  if (!res.ok) { const t = await res.text(); console.error("anthropic schedule", res.status, t.slice(0, 500)); return json({ error: `Anthropic API ${res.status}` }, 502); }
  const out = await res.json();
  const txt = (out.content || []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("").replace(/```(?:json)?/gi, "");
  let sc: any; try { sc = JSON.parse(txt.slice(txt.indexOf("{"), txt.lastIndexOf("}") + 1)); } catch { return json({ error: `the reply wasn't readable (stop: ${out.stop_reason})` }, 502); }
  const games = (Array.isArray(sc.games) ? sc.games : []).filter((g: any) => /^\d{4}-\d{2}-\d{2}$/.test(g?.date || "") && (g.home || g.away)).slice(0, 2000)
    .map((g: any) => ({ date: g.date, time: /^\d{1,2}:\d{2}$/.test(g.time || "") ? g.time : null, home: str(g.home, 80), away: str(g.away, 80), table: g.table ? str(g.table, 30) : null, week: g.week ? str(g.week, 60) : null, playoff: !!g.playoff, round: g.round ? str(g.round, 40) : null }));
  return json({ schedule: { year: Number(sc.year) || null, venue: sc.venue ? str(sc.venue, 200) : "", games } });
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
    if (body.action === "schedule") return await readSchedule(body, u.user.id, KEY, url, service);
    if (body.action === "visit") return await recordVisit(req, body, asUser, url, service);
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
    const P = await prompts(url, service), VOICES = await voicesList(url, service);
    const pool = VOICES.filter(v => !used.has(v.name));
    const voice = (pool.length ? pool : VOICES)[Math.floor(Math.random() * (pool.length || VOICES.length))];
    const system = (P.report_system || FALLBACK_REPORT) + (P.report_voice_note || FALLBACK_VOICE_NOTE).replaceAll("{name}", voice.name).replaceAll("{style}", voice.style);

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
        system,
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
      voice: voice.name,
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
