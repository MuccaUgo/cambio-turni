# Cambio turni

Strumento tra colleghi per trovare in fretta chi ti copre. Niente manager,
niente approvazioni: il cambio vero si fa sempre su **UKG**, qui ci si mette
d'accordo. Pensato per ~100 persone, ottimizzato per iPhone.

## Come funziona

1. **Chiedo.** Tocco il giorno sul calendario e scelgo cosa mi serve:
   - 🕘 **Cambio orario** — "il 31 agosto vorrei iniziare alle 9:30"
   - 📅 **Giorno off** — "quel giorno vorrei essere libero, chi copre il mio turno?"

   Non serve dire il perché. Posso indicare il turno che ho adesso, così i
   colleghi capiscono al volo cosa prenderebbero.

   Per il **giorno off** indico anche **quali giorni do in cambio**: sotto
   compaiono i sette giorni della settimana (il giorno richiesto è escluso) e
   ne posso toccare quanti voglio. Per ognuno posso aggiungere *"preferirei
   entrare alle…"*, ma **l'orario è facoltativo**: se non lo scelgo resta solo
   il giorno. Ritoccando l'orario già selezionato lo tolgo.
   Esempio: sono libero martedì e giovedì ma mi serve venerdì → chiedo venerdì
   off e offro martedì dalle 14:00 e giovedì senza preferenza. I colleghi
   leggono l'offerta sulla richiesta e sanno subito se gli torna.

2. **Qualcuno risponde.** Gli altri vedono la richiesta sul calendario e in
   bacheca. Chi può tocca **"Ci penso io"**, dice a che ora inizia lui e se
   vuole lascia un **commento** ("ci sono ma arrivo dieci minuti dopo").
   Chi non può può segnare **"Non posso"** (facoltativo: serve solo a far
   sapere che ha guardato).

   **Chi ha accettato lo vedono solo i due interessati.** Per tutti gli altri
   la richiesta risulta semplicemente "in pending", senza nome, senza orario
   e senza commento.

3. **In pending.** La richiesta passa in attesa e compare a chi l'ha fatta e a
   chi l'ha presa, con il pulsante **Apri UKG** che porta dritto al portale in
   una scheda nuova. Lì i due fanno il cambio per davvero.

4. **Risolto.** Quando UKG l'ha registrato, uno dei due tocca **Risolto** e la
   richiesta sparisce dal calendario.

In qualsiasi momento **sia chi ha chiesto sia chi ha accettato** possono
**tornare all'inizio** (la richiesta torna disponibile per tutti) o
**annullare**. Anche una richiesta già risolta si può riaprire, se è stata
chiusa per sbaglio.

Gli orari vanno dalle **8:00 alle 18:00**, a passi di mezz'ora.
La settimana va da **sabato a venerdì**.

## I simboli del calendario

Il calendario resta pulito: la legenda sta in fondo alla schermata, sotto
"Cosa vuol dire ogni simbolo".

L'orologio è il cambio orario, il calendarietto è il giorno off.
Ambra = ancora da prendere, verde acqua = in pending.
L'icona nuda è di un collega, l'icona dentro la pastiglia colorata è tua.

| | |
|---|---|
| 🕘 ambra | Cambio orario disponibile |
| 📅 ambra | Giorno off richiesto |
| 🕘 verde acqua | Cambio orario in pending |
| 📅 verde acqua | Giorno off in pending |
| 🕘 ambra in pastiglia | Mio cambio orario proposto |
| 📅 ambra in pastiglia | Mio giorno off proposto |
| 🕘 verde acqua in pastiglia | Mio cambio orario in pending |
| 📅 verde acqua in pastiglia | Mio giorno off in pending |

Quando una richiesta è risolta sparisce dal calendario: resta nella bacheca.

## Accesso

Nome e cognome + un **codice di 6 cifre** che scegli tu. Niente email, niente
password, niente conferme. Per rientrare scegli il tuo nome dall'elenco e
digiti il codice sul tastierino.

La **prima persona che si registra** tiene le chiavi di casa: non approva
niente, può solo reimpostare il codice di chi l'ha dimenticato e togliere
dall'elenco chi non lavora più con voi. Può passare questo compito a qualcun
altro dalla scheda Profilo.

---

## Stato

**L'app è in funzione** su https://muccaugo.github.io/cambio-turni/, collegata
al progetto Supabase `CambioTurni` (`mhocwnewwjxmcrynyrrz`). Le istruzioni qui
sotto servono solo per rifarla da zero o per ricostruirla altrove.

Se pubblico una versione nuova e non la vedi, in **Profilo** c'è *Ricarica
l'app*: salta la cache. Per i soli dati bastano il tasto ↻ nell'intestazione
del calendario o *Aggiorna* in bacheca — e comunque si riscaricano da soli
ogni volta che riapri l'app.

## Installazione

### 1. Crea il database

1. Vai su [supabase.com](https://supabase.com) → **New project** (il piano gratuito basta).
2. Apri **SQL Editor** → **New query**.
3. Incolla tutto [`supabase-setup.sql`](supabase-setup.sql) e premi **Run**.

Puoi rieseguirlo quando vuoi, ma **cancella tutti i dati**: le prime righe
fanno `drop table`.

### 2. Collega l'app

In **Project Settings → API** copia due valori e incollali nello `<script>` di
[`index.html`](index.html) (righe 388-389):

```js
const SUPABASE_URL = "https://xxxxxxxx.supabase.co";
const SUPABASE_KEY = "sb_publishable_...";   // chiave pubblica / anon
```

Poco sotto c'è già l'indirizzo di UKG, usato dal pulsante **Apri UKG** che sta
sotto al calendario e sulle richieste in pending. Si apre in una scheda nuova:
il portale non si lascia incorporare dentro l'app (l'SSO si accorge di essere
in un iframe e rifiuta il login), ed è giusto così.

```js
const UKG_URL = "https://applecomputer-sso.prd.mykronos.com";
```

La chiave pubblica è fatta per stare nel browser: da sola non dà accesso a
nulla, perché le tabelle sono chiuse e tutto passa dalle funzioni `api_*`.

Finché i due valori restano i segnaposto, l'app parte in **modalità demo** con
12 colleghi finti salvati solo su quel telefono: utile per far provare
l'interfaccia. Puoi forzarla aggiungendo `?demo=1` all'indirizzo.

### 3. Pubblica

Repo su GitHub → **Settings → Pages → Deploy from a branch → main / root**.
Sono file statici, non serve altro.

Per provare in locale:

```bash
python3 -m http.server 4190 --directory cambio-turni
```

### 4. Primo giro

Registrati tu per primo, poi manda il link agli altri. Dì al team di
aggiungere l'app alla schermata Home dell'iPhone (**Condividi → Aggiungi a
Home**): si apre a tutto schermo come un'app vera.

---

## Sicurezza

Livello basso e volutamente semplice, come concordato: qui dentro ci sono
nomi, date e orari di turno, niente di sensibile. Quello che c'è comunque:

- il codice di 6 cifre non è salvato in chiaro (hash bcrypt)
- i token di sessione sono casuali da 32 byte, salvati solo come SHA-256, validi 90 giorni
- le tabelle non sono raggiungibili dalla chiave pubblica: RLS attiva, `GRANT`
  revocati, ogni operazione passa da funzioni `SECURITY DEFINER` che
  controllano il token
- massimo 10 tentativi sbagliati in 15 minuti per persona
- l'identità di chi accetta una richiesta (nome, orario, commento) esce dal
  database **solo** verso chi ha chiesto e chi ha accettato: il filtro è in
  `swaps_json`, non nell'interfaccia, quindi non basta smanettare col browser

I limiti da conoscere: l'elenco dei nomi è visibile prima di entrare (serve per
scegliere il proprio) e un codice di 6 cifre è indovinabile da chi ha tempo e
pazienza. Chiunque abbia il link e un nome libero può registrarsi.

**Se un domani serve più sicurezza**, in ordine di fatica crescente:

1. Aggiungere un codice di invito per il team alla registrazione (una tabella
   `access_codes` e un controllo dentro `api_register`).
2. Nascondere l'elenco dei nomi e chiedere di digitare il proprio.
3. Passare a Supabase Auth con email vere e magic link.

## Note pratiche

- Piano gratuito: il progetto Supabase va in pausa dopo circa una settimana di
  inattività e non ci sono backup automatici.
- Chi cambia telefono rientra con nome e codice.
- Chi dimentica il codice lo fa reimpostare da chi gestisce l'elenco.
- Non ci sono notifiche push: la bacheca mostra il numero di richieste aperte
  sul badge della tab.

## File

| File | Cosa contiene |
|---|---|
| `index.html` | tutta l'app: interfaccia, logica, modalità demo |
| `supabase-setup.sql` | tabelle, funzioni `api_*`, permessi |
| `manifest.json`, `icon*.png`, `icon.svg` | icona e installazione sulla Home |
