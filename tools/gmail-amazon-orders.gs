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
      const parsed = parse_(msg, isBackfill);
      if (!send) { Logger.log(JSON.stringify(parsed || { unparsed: msg.getSubject() })); continue; }
      if (!parsed) { thread.addLabel(bad); continue; }
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
    if (send && !thread.getLabels().some(l => l.getName() === LABEL_BAD)) thread.addLabel(sent);
  }
  Logger.log('%s sent', n);
}

function parse_(msg, isBackfill) {
  const text = msg.getSubject() + '\n' + msg.getPlainBody();
  const id = (text.match(ORDER_ID) || [])[1];
  if (!id) return null;
  const at = msg.getDate().toISOString();
  if (CANCELLED.test(msg.getSubject())) {
    return { kind: 'purchase.cancelled', payload: { source: 'amazon', order_id: id, cancelled_at: at, email_id: msg.getId() } };
  }
  const m = text.match(TOTAL);
  if (!m) return null;
  return { kind: 'purchase.detected', payload: {
    source: 'amazon', order_id: id, ordered_at: at, total: Number(m[1].replace(/,/g, '')), currency: 'JPY',
    email_id: msg.getId(), backfill: isBackfill || undefined,
  } };   // items omitted: Amazon's item lines are not reliably parseable; Cost lets you edit on Log
}

function label_(name) { return GmailApp.getUserLabelByName(name) || GmailApp.createLabel(name); }
