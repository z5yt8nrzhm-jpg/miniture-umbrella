// Builds the notification emails. Kept free of any Supabase or network code so
// it can be tested on its own (see email.test.ts).

export type Row = Record<string, unknown>;
export type Email = { subject: string; html: string; text: string };

const KIND: Record<string, string> = {
  event_request: 'event request',
  partner_request: 'partner request',
  signup: 'list sign-up',
  event_signup: 'event sign-up',
};

export function escapeHtml(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}

const clip = (s: unknown, n: number) => String(s ?? '').slice(0, n);

export function leadEmail(lead: Row, deskUrl: string): Email {
  const kind = KIND[String(lead.kind)] ?? 'message';
  const name = clip(lead.name, 60);
  const fields = (lead.fields && typeof lead.fields === 'object' ? lead.fields : {}) as Row;
  const lines = [
    `Name: ${name}`,
    `Contact: ${clip(lead.contact, 120)}`,
    ...Object.entries(fields).slice(0, 20).map(([k, v]) => `${clip(k, 60)}: ${clip(v, 600)}`),
    ...(lead.source ? [`From: ${clip(lead.source, 40)}`] : []),
    `OK to send news: ${lead.consent ? 'yes' : 'no'}`,
  ];
  const subject = `New ${kind}: ${name}`.replace(/[\r\n]+/g, ' ');
  return {
    subject,
    text: `${lines.join('\n')}\n\nOpen the inbox: ${deskUrl}`,
    html: `<p><strong>New ${escapeHtml(kind)}</strong></p><p>${lines.map(escapeHtml).join('<br>')}</p><p><a href="${escapeHtml(deskUrl)}">Open the inbox</a></p>`,
  };
}

export function postEmail(post: Row, deskUrl: string): Email {
  const title = clip(post.title, 100);
  const author = clip(post.author_name, 60);
  const subject = `Journal post waiting for review: ${title}`.replace(/[\r\n]+/g, ' ');
  return {
    subject,
    text: `${author} sent "${title}" for review.\n\nOpen the journal: ${deskUrl}`,
    html: `<p><strong>${escapeHtml(author)}</strong> sent <em>${escapeHtml(title)}</em> for review.</p><p><a href="${escapeHtml(deskUrl)}">Open the journal</a></p>`,
  };
}

// What a database webhook sends -> the email to send, or null to ignore it.
export function emailFor(payload: Row, deskUrl: string): Email | null {
  const rec = payload.record as Row | undefined;
  const old = payload.old_record as Row | undefined;
  if (!rec) return null;
  if (payload.table === 'leads' && payload.type === 'INSERT') return leadEmail(rec, deskUrl);
  if (payload.table === 'journal_posts' && rec.status === 'submitted' && old?.status !== 'submitted') return postEmail(rec, deskUrl);
  return null;
}
