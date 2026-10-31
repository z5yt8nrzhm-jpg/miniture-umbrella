// Run: node --experimental-strip-types supabase/functions/notify/email.test.ts
import assert from 'node:assert/strict';
import { emailFor, leadEmail, postEmail, escapeHtml } from './email.ts';

const lead = { kind: 'event_request', name: 'Mary <b>Host</b>', contact: 'mary@example.test', consent: true, source: 'instagram',
  fields: { Event: 'Sound bath', Idea: '<script>alert(1)</script>' } };
const m = leadEmail(lead, 'https://desk.example/studio.html');
assert.equal(m.subject, 'New event request: Mary <b>Host</b>');
assert.ok(m.text.includes('Event: Sound bath') && m.text.includes('From: instagram') && m.text.includes('OK to send news: yes'));
assert.ok(!m.html.includes('<script>') && !m.html.includes('<b>Host') && m.html.includes('&lt;script&gt;'), 'markup in a form is escaped in the email');

const sneaky = leadEmail({ kind: 'signup', name: 'Eve\r\nBcc: attacker@example.test', contact: 'x@example.test', fields: {} }, '');
assert.ok(!/[\r\n]/.test(sneaky.subject), 'a name cannot add email headers');

assert.equal(escapeHtml(`"'&<>`), '&quot;&#39;&amp;&lt;&gt;');
assert.equal(leadEmail({ kind: 'nope', name: 'A', contact: 'a@example.test', fields: 'not an object' }, '').subject, 'New message: A');
assert.ok(leadEmail({ kind: 'signup', name: 'A', contact: 'a@example.test', fields: {} , consent: false}, '').text.includes('OK to send news: no'));
assert.ok(leadEmail({ kind: 'signup', name: 'N', contact: 'c@example.test', fields: { k: 'x'.repeat(5000) } }, '').text.length < 1200, 'long answers are cut');

assert.ok(emailFor({ type: 'INSERT', table: 'leads', record: lead }, 'u'));
assert.equal(emailFor({ type: 'UPDATE', table: 'leads', record: lead }, 'u'), null, 'edits to a lead do not email');
assert.equal(emailFor({ type: 'INSERT', table: 'other', record: {} }, 'u'), null);
assert.equal(emailFor({ type: 'INSERT', table: 'leads' }, 'u'), null);
const post = { title: 'Meet Tess', author_name: 'Tara', status: 'submitted' };
assert.ok(emailFor({ type: 'UPDATE', table: 'journal_posts', record: post, old_record: { status: 'draft' } }, 'u')!.subject.includes('Meet Tess'));
assert.equal(emailFor({ type: 'UPDATE', table: 'journal_posts', record: post, old_record: { status: 'submitted' } }, 'u'), null, 'only the moment it is sent for review');
assert.equal(emailFor({ type: 'UPDATE', table: 'journal_posts', record: { ...post, status: 'published' }, old_record: { status: 'submitted' } }, 'u'), null);
assert.ok(postEmail({ title: '<i>x</i>', author_name: 'T' }, '').html.includes('&lt;i&gt;'));
console.log('notify email: all checks passed');
