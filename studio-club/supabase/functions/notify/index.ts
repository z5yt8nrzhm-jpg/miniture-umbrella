// Emails the studio when a form comes in or a teacher sends a post for review.
//
// Set up (see the README): deploy this function, add two Database Webhooks
// (table `leads` on INSERT, table `journal_posts` on UPDATE) that call it with
// the header `x-webhook-secret`, and set these secrets:
//   WEBHOOK_SECRET   any long random text, the same as in the webhooks
//   RESEND_API_KEY   from resend.com (or swap the fetch below for your provider)
//   NOTIFY_TO        who to email, e.g. studio@example.com (comma separated is fine)
//   NOTIFY_FROM      a sender your provider allows, e.g. "Gilbert Flex <hello@yourdomain>"
//   DESK_URL         where studio.html is hosted
import { emailFor } from './email.ts';

Deno.serve(async (req) => {
  const secret = Deno.env.get('WEBHOOK_SECRET');
  if (!secret || req.headers.get('x-webhook-secret') !== secret) return new Response('forbidden', { status: 403 });
  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return new Response('bad request', { status: 400 }); }

  const mail = emailFor(payload, Deno.env.get('DESK_URL') ?? '');
  if (!mail) return new Response('ignored');

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}` },
    body: JSON.stringify({
      from: Deno.env.get('NOTIFY_FROM'),
      to: (Deno.env.get('NOTIFY_TO') ?? '').split(',').map((s) => s.trim()).filter(Boolean),
      subject: mail.subject, html: mail.html, text: mail.text,
    }),
  });
  // A failure here must not lose the lead: it is already saved. Report it so the webhook log shows it.
  return new Response(res.ok ? 'sent' : 'email failed', { status: res.ok ? 200 : 502 });
});
