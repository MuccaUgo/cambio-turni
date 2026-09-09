// ============================================================
// Cambio turni — lettura del calendario dei turni
//
// Il browser non può scaricare il feed .ics da solo: il CORS glielo
// impedisce (verificato dall'origine muccaugo.github.io). Questa
// funzione lo fa al suo posto e restituisce i turni già puliti.
//
// NON SALVA NIENTE. Né il link né i turni toccano il database: entrano
// con la richiesta, escono con la risposta, e vivono solo sul telefono
// di chi ha chiamato. È una scelta esplicita: i turni sono un dato
// personale e restano dove sta la persona.
//
// L'autenticazione la fa da sé col token di sessione dell'app, come
// `notifica`: per questo è pubblicata senza il controllo JWT.
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function sha256hex(s: string) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/* ------------------------------------------------------------
   L'indirizzo lo sceglie chi chiama, quindi va tenuto al guinzaglio:
   senza un elenco chiuso questa funzione diventa il modo per far
   bussare il server a indirizzi interni che decide qualcun altro.
   ------------------------------------------------------------ */
function hostAmmesso(h: string) {
  return h === "sm-cal.apple.com"
    || h === "calendars.icloud.com"
    || /^p\d{1,3}-calendars\.icloud\.com$/.test(h);
}

function normalizza(raw: string): URL {
  const s = String(raw ?? "").trim().replace(/^webcal:\/\//i, "https://");
  if (!s) throw new Error("URL_MANCANTE");
  let u: URL;
  try { u = new URL(s); } catch { throw new Error("URL_NON_VALIDO"); }
  if (u.protocol !== "https:") throw new Error("SOLO_HTTPS");
  if (!hostAmmesso(u.hostname)) throw new Error("HOST_NON_AMMESSO");
  return u;
}

const MAX_BYTE = 5_000_000;

async function scarica(partenza: URL) {
  let u = partenza;
  for (let salto = 0; salto < 4; salto++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12_000);
    let r: Response;
    try {
      r = await fetch(u.toString(), { redirect: "manual", signal: ctrl.signal });
    } catch (_) {
      throw new Error("FEED_IRRAGGIUNGIBILE");
    } finally {
      clearTimeout(timer);
    }
    if (r.status >= 300 && r.status < 400) {
      const loc = r.headers.get("location");
      if (!loc) throw new Error("REDIRECT_SENZA_META");
      // ogni salto passa dallo stesso controllo del primo
      u = normalizza(new URL(loc, u).toString());
      continue;
    }
    if (!r.ok) throw new Error("FEED_HTTP_" + r.status);
    if (Number(r.headers.get("content-length") || 0) > MAX_BYTE) throw new Error("FEED_TROPPO_GRANDE");
    const testo = await r.text();
    if (testo.length > MAX_BYTE) throw new Error("FEED_TROPPO_GRANDE");
    return testo;
  }
  throw new Error("TROPPI_REDIRECT");
}

/* ------------------------------------------------------------
   Lettura dell'.ics — la parte facile, per fortuna: il feed di UKG
   non ha ricorrenze (RRULE), cancellazioni (EXDATE) né stati, quindi
   ogni evento si legge per conto suo. Due sole forme:
     • turno    DTSTART;TZID=Europe/Rome:20260921T110000
     • assenza  DTSTART;VALUE=DATE:20260811        (tutto il giorno)
   ------------------------------------------------------------ */
function campo(blocco: string, nome: string) {
  const m = blocco.match(new RegExp(`^${nome}([^:\\r\\n]*):(.*)$`, "m"));
  return m ? { par: m[1] || "", val: m[2].trim() } : null;
}

const dataDi = (s: string) => `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;
const oraDi  = (s: string) => `${s.slice(9, 11)}:${s.slice(11, 13)}`;

// Gli orari con la Z finale sono in UTC: qui interessa l'ora dell'orologio
// a Roma, che è quella che il collega legge sul suo turno.
function daUTC(s: string) {
  const d = new Date(`${dataDi(s)}T${oraDi(s)}:${s.slice(13, 15) || "00"}Z`);
  const p = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Europe/Rome", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(d);
  return { d: p.slice(0, 10), t: p.slice(11, 16) };
}
const quando = (v: string) => v.endsWith("Z") ? daUTC(v) : { d: dataDi(v), t: oraDi(v) };

// Le etichette arrivano grezze da UKG: "ITA Time Away F 08.00 hrs",
// "ITA PH Not Wrkd 08.00 hrs", "ITA Public Holiday Off 08.00 hrs".
// "PH" sta per public holiday e non contiene la parola per esteso.
function tipoAssenza(sommario: string) {
  const s = sommario.toLowerCase();
  if (s.includes("holiday") || /\bph\b/.test(s)) return "festivo";
  if (s.includes("time away") || s.includes("vacation") || s.includes("leave")) return "ferie";
  return "assenza";
}

function leggi(ics: string) {
  // le righe lunghe di un .ics sono spezzate a 75 caratteri e la
  // continuazione comincia con uno spazio: prima si ricuce tutto
  const piatto = ics.replace(/\r?\n[ \t]/g, "");
  const turni: { d: string; inizio: string; fine: string }[] = [];
  const assenze: { d: string; tipo: string }[] = [];

  for (const pezzo of piatto.split("BEGIN:VEVENT").slice(1)) {
    const blocco = pezzo.split("END:VEVENT")[0];
    const st = campo(blocco, "DTSTART");
    if (!st) continue;
    const en = campo(blocco, "DTEND");
    const sommario = campo(blocco, "SUMMARY")?.val ?? "";

    if (/VALUE=DATE/i.test(st.par)) {
      // assenza di una o più giornate intere. In un .ics il DTEND di un
      // evento tutto-il-giorno è il giorno DOPO l'ultimo: 11→12 vuol dire
      // solo l'11. Quindi si conta fino a DTEND escluso.
      const tipo = tipoAssenza(sommario);
      const primo = dataDi(st.val);
      const oltre = en ? dataDi(en.val) : null;
      let g = primo;
      for (let i = 0; i < 400; i++) {
        assenze.push({ d: g, tipo });
        const x = new Date(`${g}T12:00:00Z`);
        x.setUTCDate(x.getUTCDate() + 1);
        g = x.toISOString().slice(0, 10);
        if (!oltre || g >= oltre) break;
      }
    } else if (en) {
      const a = quando(st.val), b = quando(en.val);
      turni.push({ d: a.d, inizio: a.t, fine: b.t });
    }
  }

  turni.sort((x, y) => x.d.localeCompare(y.d) || x.inizio.localeCompare(y.inizio));
  assenze.sort((x, y) => x.d.localeCompare(y.d));
  const giorni = [...turni.map((t) => t.d), ...assenze.map((a) => a.d)].sort();
  return { turni, assenze, dal: giorni[0] ?? null, al: giorni[giorni.length - 1] ?? null };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { token, url } = await req.json().catch(() => ({}));
    if (!token || !url) return json({ error: "PARAMETRI_MANCANTI" }, 400);

    const { data: sess } = await sb.from("sessions")
      .select("member_id")
      .eq("token_hash", await sha256hex(token))
      .gt("expires_at", new Date().toISOString())
      .maybeSingle();
    if (!sess) return json({ error: "NON_AUTENTICATO" }, 401);

    const testo = await scarica(normalizza(url));
    if (!testo.includes("BEGIN:VCALENDAR")) return json({ error: "NON_E_UN_CALENDARIO" }, 400);

    const esito = leggi(testo);
    if (!esito.turni.length && !esito.assenze.length) {
      return json({ error: "CALENDARIO_VUOTO" }, 400);
    }
    // e qui finisce: niente insert, niente update, niente da nessuna parte
    return json({ ok: true, ...esito });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 400);
  }
});
