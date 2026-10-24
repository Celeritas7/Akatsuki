/**
 * Gmail → Akatsuki: Amazon.co.jp order emails become purchase.detected / purchase.cancelled for Cost.  R048 (was R037)
 *
 * Install (once, in your own Google account):
 *   1. script.google.com → New project → paste this file.
 *   2. Project Settings → Script properties:
 *        AKATSUKI_URL    https://wylxvmkcrexwfpjpbhyy.supabase.co/functions/v1/akatsuki-mail
 *        AKATSUKI_TOKEN  the value akatsuki_ingest_token_new('gmail', 'mail') returned (never commit it)
 *   3. Run `dryRun` once and read the log: it parses without sending.  Grant Gmail access when asked.
 *   4. Run `installTrigger` once → `run` every 15 minutes.
 *   5. Optional: `backfill` sends older orders tagged backfill:true (Cost shows them as "past order").
 *
 * Sent emails get the Gmail label akatsuki/sent and are never read again.  Remove the label to resend;
 * the hub dedupes on <source>:<order_id>:<kind>, so a resend is skipped, not doubled.
 *
 * PARSING IS BEST-EFFORT.  Amazon.co.jp changes its email layout without notice.  Check the
 * SENDERS and patterns below against your real emails before trusting them.  Anything that cannot be
 * parsed is labelled akatsuki/unparsed and skipped — never guessed.
 */

const SENDERS = 'from:(auto-confirm@amazon.co.jp OR order-update@amazon.co.jp)';
const LABEL_SENT = 'akatsuki/sent';
const LABEL_BAD = 'akatsuki/unparsed';
const PER_RUN = 50;
// Emails never to send again, whatever their labels.  Gmail message ids.
//   19f474bcfba05c44  order 249-5735958-9677403 (Jul 9): its extra lines were logged by hand on 2026-10-24.
const DONE_EMAILS = ['19f474bcfba05c44'];

const ORDER_ID = /\b(\d{3}-\d{7}-\d{7})\b/;
const TOTAL = /(?:ご請求額|注文合計|合計|Order Total|Grand Total)[^\d¥￥]{0,20}[¥￥]\s?([\d,]+)/;
const CANCELLED = /キャンセル|cancell?ed/i;

function run() { process_(`${SENDERS} newer_than:3d -label:${LABEL_SENT} -label:${LABEL_BAD}`, false, true); }
function dryRun() { process_(`${SENDERS} newer_than:30d`, false, false); }
function backfill() { process_(`${SENDERS} older_than:3d -label:${LABEL_SENT} -label:${LABEL_BAD}`, true, true); }

function installTrigger() {
  ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === 'run').forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('run').timeBased().everyMinutes(15).create();
}

function process_(query, isBackfill, send) {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('AKATSUKI_URL'), token = props.getProperty('AKATSUKI_TOKEN');
  if (send && (!url || !token)) throw new Error('Set AKATSUKI_URL and AKATSUKI_TOKEN in Script properties');
  const sent = label_(LABEL_SENT), bad = label_(LABEL_BAD);
  let n = 0;

  for (const thread of GmailApp.search(query, 0, PER_RUN)) {
    for (const msg of thread.getMessages()) {
      if (DONE_EMAILS.includes(msg.getId())) continue;
      const orders = parse_(msg, isBackfill);   // one email can hold several orders
      if (!send) { Logger.log(JSON.stringify(orders.length ? orders : { unparsed: msg.getSubject() })); continue; }
      if (!orders.length) { thread.addLabel(bad); continue; }
      for (const parsed of orders) {
        const res = UrlFetchApp.fetch(url, {
          method: 'post', contentType: 'application/json', muteHttpExceptions: true,
          headers: { Authorization: 'Bearer ' + token }, payload: JSON.stringify(parsed),
        });
        const code = res.getResponseCode();
        if (code === 401) throw new Error('Token rejected — mint a new one and update AKATSUKI_TOKEN');
        if (code === 422) { Logger.log('rejected %s: %s', parsed.payload.order_id, res.getContentText()); thread.addLabel(bad); continue; }
        if (code >= 300) { Logger.log('hub %s — retried next run', code); return; }   // leave unlabelled
        n++;
      }
    }
    if (send && !thread.getLabels().some(l => l.getName() === LABEL_BAD)) thread.addLabel(sent);
  }
  Logger.log('%s sent', n);
}

// Returns a list: one purchase.* per order in the email.  Amazon sometimes confirms several orders in one
// email, each block starting with "Order #" and carrying its own items and Total.  Items are sent only when
// they add up to that block's total; otherwise the order goes with its total alone (never a wrong split).
const ORDER_LABEL = /^(?:order\s*#|注文番号)/i;
function blocksOf_(text) {
  const lines = text.split('\n');
  const starts = lines.map((l, i) => (ORDER_LABEL.test(l.trim()) ? i : -1)).filter(i => i >= 0);
  if (starts.length < 2) return [text];
  return starts.map((st, k) => lines.slice(st, k + 1 < starts.length ? starts[k + 1] : lines.length).join('\n'));
}
function parse_(msg, isBackfill) {
  const text = msg.getSubject() + '\n' + msg.getPlainBody();
  const at = msg.getDate().toISOString();
  if (CANCELLED.test(msg.getSubject())) {
    const id = (text.match(ORDER_ID) || [])[1];
    return id ? [{ kind: 'purchase.cancelled', payload: { source: 'amazon', order_id: id, cancelled_at: at, email_id: msg.getId() } }] : [];
  }
  const out = [];
  for (const block of blocksOf_(text)) {
    const id = (block.match(ORDER_ID) || [])[1];
    const total = totalOf_(block);
    if (!id || total == null) continue;
    let items = itemsOf_(block);
    if (items && items.some(it => it.price == null || items.reduce((a, b) => a + (b.price || 0), 0) !== total)) {
      Logger.log('items for %s do not add up to %s — sending the total only', id, total);
      items = undefined;
    }
    out.push({ kind: 'purchase.detected', payload: {
      source: 'amazon', order_id: id, ordered_at: at, total, currency: 'JPY',
      items, email_id: msg.getId(), backfill: isBackfill || undefined,
    } });
  }
  return out;
}

// Total, two layouts:
//   one line   "Order Total: ￥1,234" / "ご請求額：￥1,234"
//   two lines  "Total" then "1,234" / "￥1,234" / "1,234 JPY" (Amazon.co.jp English emails, 2026)
const TOTAL_LABEL = /^(?:order\s+total|grand\s+total|total|ご請求額|注文合計|合計)\s*[:：]?$/i;
const AMOUNT_LINE = /^(?:JPY|[¥￥])?\s*([\d,]+)(?:\.\d+)?\s*(?:JPY|円)?$/i;
function totalOf_(text) {
  const one = text.match(TOTAL);
  if (one) return Number(one[1].replace(/,/g, ''));
  const lines = text.split('\n').map(s => s.trim());
  for (let i = 0; i < lines.length; i++) {
    if (!TOTAL_LABEL.test(lines[i])) continue;
    for (const next of lines.slice(i + 1, i + 4).filter(Boolean)) {
      const m = next.match(AMOUNT_LINE);
      if (m) return Number(m[1].replace(/,/g, ''));
    }
  }
  return null;
}

// Items, Amazon.co.jp English layout (2026):
//   * <item name>
//   Quantity: <n>
//   <amount> JPY          ← the amount Amazon shows for that line
// Returns [] when the layout isn't there; the order still goes through with its total.
const ITEM_START = /^\*\s+(.+)$/;
const QTY_LINE = /^(?:Quantity|数量)\s*[:：]\s*(\d+)/i;
function itemsOf_(text) {
  const lines = text.split('\n').map(s => s.trim()).filter(Boolean);
  const items = [];
  for (let i = 0; i < lines.length && items.length < 30; i++) {
    const m = lines[i].match(ITEM_START);
    if (!m) continue;
    const it = { name: m[1].slice(0, 60) };
    for (const next of lines.slice(i + 1, i + 4)) {
      if (ITEM_START.test(next) || TOTAL_LABEL.test(next)) break;
      const q = next.match(QTY_LINE); if (q) { it.qty = Number(q[1]); continue; }
      const a = next.match(AMOUNT_LINE); if (a && it.price == null) it.price = Number(a[1].replace(/,/g, ''));
    }
    items.push(it);
  }
  return items.length ? items : undefined;
}

function label_(name) { return GmailApp.getUserLabelByName(name) || GmailApp.createLabel(name); }

// Diagnostic: shows how the newest Amazon email presents its order number and total.  Sends nothing.
function debugLast() {
  const t = GmailApp.search(`${SENDERS} newer_than:30d`, 0, 1)[0];
  if (!t) return Logger.log('no Amazon email found');
  const m = t.getMessages()[0], body = m.getPlainBody();
  const id = (body.match(/\d{3}-\d{7}-\d{7}/) || [])[0];
  Logger.log('subject: ' + m.getSubject());
  Logger.log('order id found: ' + (id ? 'yes, ends ' + id.slice(-4) : 'NO'));
  Logger.log('total read as: ' + totalOf_(m.getSubject() + '\n' + body));
  const lines = body.split('\n').map(s => s.trim()).filter(Boolean);
  const i = lines.findIndex(s => TOTAL_LABEL.test(s));
  if (i >= 0) lines.slice(i, i + 4).forEach(s => Logger.log('> ' + s.slice(0, 120)));
}

// Diagnostic for one order: how the email splits into orders and what would be sent.  Sends nothing.
const DEBUG_ORDER = '249-5735958-9677403';
function debugOrder() {
  const t = GmailApp.search(`${SENDERS} ${DEBUG_ORDER}`, 0, 1)[0];
  if (!t) return Logger.log('no email for ' + DEBUG_ORDER);
  const m = t.getMessages()[0], body = m.getPlainBody();
  const lines = body.split('\n').map(s => s.trim()).filter(Boolean);
  lines.forEach((s, i) => { if (ORDER_LABEL.test(s) || TOTAL_LABEL.test(s) || ORDER_ID.test(s) && s.length < 30) Logger.log('line %s: %s', i, s.slice(0, 60)); });
  parse_(m, false).forEach(o => Logger.log('-> %s total %s, %s items', o.payload.order_id, o.payload.total, (o.payload.items || []).length));
}
