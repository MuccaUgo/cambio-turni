// ============================================================
// Cambio turni — invio delle notifiche push
//
// La chiama l'app subito dopo un'azione riuscita. NON si fida del client
// su chi vada avvisato: riceve solo l'id della richiesta e il tipo di
// evento, e ricalcola i destinatari leggendo il database.
//
// L'autenticazione la fa da sé, con il token di sessione dell'app: per
// questo la funzione è pubblicata senza il controllo JWT di Supabase.
// ============================================================
import webpush from "npm:web-push@3.6.7";
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

const MESI = ["gennaio","febbraio","marzo","aprile","maggio","giugno",
              "luglio","agosto","settembre","ottobre","novembre","dicembre"];
const GG = ["domenica","lunedì","martedì","mercoledì","giovedì","venerdì","sabato"];

function dataLunga(iso: string) {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  return `${GG[dt.getUTCDay()]} ${d} ${MESI[m - 1]}`;
}

async function sha256hex(s: string) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

let vapidPronto = false;
async function preparaVapid() {
  if (vapidPronto) return;
  const { data } = await sb.from("app_secrets").select("name, value")
    .in("name", ["vapid_public", "vapid_private"]);
  const m = Object.fromEntries((data ?? []).map((r) => [r.name, r.value]));
  if (!m.vapid_public || !m.vapid_private) throw new Error("VAPID mancanti");
  // il "subject" arriva al servizio push come recapito: usiamo il sito, non un'email
  webpush.setVapidDetails(
    "https://muccaugo.github.io/cambio-turni/",
    m.vapid_public,
    m.vapid_private,
  );
  vapidPronto = true;
}

// Spedisce a un elenco di persone. Le iscrizioni morte si buttano: quel
// telefono non c'è più, o l'app è stata tolta dalla Home.
async function spedisci(destinatari: string[], titolo: string, corpo: string, tag: string) {
  if (!destinatari.length) return json({ ok: true, inviate: 0, motivo: "nessun destinatario" });

  // gli errori del database vanno detti, non ingoiati: un "nessuno ha
  // attivato" che in realtà era un errore fa perdere un pomeriggio
  const { data: subs, error: errSubs } = await sb.from("push_subs")
    .select("endpoint, p256dh, auth, member_id")
    .in("member_id", destinatari);
  if (errSubs) return json({ error: "DB push_subs: " + errSubs.message }, 500);
  if (!subs?.length) return json({ ok: true, inviate: 0, motivo: "nessuno ha attivato le notifiche" });

  await preparaVapid();
  const payload = JSON.stringify({ title: titolo, body: corpo, tag });

  const esiti = await Promise.allSettled(subs.map((s) =>
    webpush.sendNotification(
      { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
      payload,
    )
  ));

  let ok = 0;
  const morte: string[] = [];
  const errori: string[] = [];
  esiti.forEach((e, i) => {
    if (e.status === "fulfilled") ok++;
    else {
      const r = e.reason as { statusCode?: number; body?: string; message?: string };
      errori.push(`${r?.statusCode ?? "?"} ${r?.body ?? r?.message ?? ""}`.slice(0, 120));
      if (r?.statusCode === 404 || r?.statusCode === 410) morte.push(subs[i].endpoint);
    }
  });
  if (morte.length) await sb.from("push_subs").delete().in("endpoint", morte);

  return json({ ok: true, inviate: ok, fallite: esiti.length - ok, rimosse: morte.length, errori });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { token, swap_id, evento } = await req.json();
    if (!token || !evento) return json({ error: "PARAMETRI_MANCANTI" }, 400);
    if (evento !== "prova" && !swap_id) return json({ error: "PARAMETRI_MANCANTI" }, 400);

    // 1. chi sta chiamando? (il token vive solo come hash)
    const { data: sess } = await sb.from("sessions")
      .select("member_id")
      .eq("token_hash", await sha256hex(token))
      .gt("expires_at", new Date().toISOString())
      .maybeSingle();
    if (!sess) return json({ error: "NOT_AUTHENTICATED" }, 401);
    const ioId = sess.member_id as string;

    const { data: io } = await sb.from("members").select("full_name").eq("id", ioId).maybeSingle();

    // "prova": la mando a chi la chiede, per verificare che tutto funzioni
    if (evento === "prova") {
      return await spedisci([ioId], "Prova riuscita 🎉",
        "Le notifiche funzionano: ti avviserò quando succede qualcosa.", "prova");
    }

    const { data: sw } = await sb.from("swaps").select("*").eq("id", swap_id).maybeSingle();
    if (!sw) return json({ error: "NOT_FOUND" }, 404);
    const { data: autore } = await sb.from("members").select("full_name").eq("id", sw.author_id).maybeSingle();

    const nome1 = (n?: string) => (n ?? "").split(" ")[0];
    const quando = dataLunga(sw.target_date);
    const cosa = sw.kind === "off" ? "giorno off" : "cambio orario";

    // 2. chi va avvisato, deciso qui e non dal client
    let destinatari: string[] = [];
    let titolo = "Cambio turni", corpo = "";

    if (evento === "aperta") {
      const { data } = await sb.from("members").select("id").eq("active", true).neq("id", sw.author_id);
      destinatari = (data ?? []).map((m) => m.id);
      titolo = `${nome1(autore?.full_name)} cerca un cambio`;
      corpo = sw.kind === "off"
        ? `${quando} · vorrebbe la giornata libera`
        : `${quando} · vorrebbe iniziare alle ${String(sw.to_time).slice(0, 5)}`;
    } else if (evento === "presa") {
      destinatari = [sw.author_id];
      titolo = `Ci pensa ${nome1(io?.full_name)}`;
      corpo = `${quando} · ${cosa}`;
    } else if (evento === "risolta") {
      destinatari = [sw.author_id, sw.taker_id];
      titolo = "Cambio risolto";
      corpo = `${quando} · ${cosa}`;
    } else if (evento === "release") {
      destinatari = [sw.author_id, sw.taker_id];
      titolo = "Il cambio torna disponibile";
      corpo = `${quando} · ${cosa}`;
    } else if (evento === "annullata") {
      destinatari = [sw.author_id, sw.taker_id];
      titolo = "Richiesta annullata";
      corpo = `${quando} · ${cosa}`;
    } else {
      return json({ error: "EVENTO_SCONOSCIUTO" }, 400);
    }

    // mai a se stessi, mai due volte
    destinatari = [...new Set(destinatari.filter((x): x is string => !!x && x !== ioId))];
    return await spedisci(destinatari, titolo, corpo, `swap-${swap_id}`);
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
