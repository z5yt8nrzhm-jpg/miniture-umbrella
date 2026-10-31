-- Starting lists for the club. Edit these in the Supabase table editor, or
-- add a new migration. The perks below are placeholders: set the rewards the
-- studio actually wants to give.

insert into public.class_types (code, name, pace, blurb, sort) values
  ('mat_pilates',   'Mat Pilates',        'steady',    'Core strength and control, on the mat. All levels.', 1),
  ('vibe_pilates',  'VIBE Mat Pilates',   'steady',    'A VIBE community class. Mats provided, beginner friendly.', 2),
  ('yoga_flow',     'Yoga Flow',          'steady',    'Move with the breath through linked poses.', 3),
  ('yoga_gentle',   'Gentle Yoga',        'calm',      'Slow, supported poses for a softer day.', 4),
  ('stretch',       'Stretch & Restore',  'calm',      'Long holds and deep breathing to unwind.', 5),
  ('strength',      'Strength & Sculpt',  'energetic', 'Resistance work for the whole body.', 6)
on conflict (code) do nothing;

insert into public.badges (code, title, blurb, kind, threshold, sort) values
  ('first_class', 'First Class',      'You showed up. That is the hardest part.',   'classes', 1,   1),
  ('classes_10',  'Ten Classes',      'Ten classes in. A habit is forming.',        'classes', 10,  2),
  ('classes_25',  'Twenty-Five',      'Twenty-five classes. Look how far you came.', 'classes', 25,  3),
  ('classes_50',  'Fifty Classes',    'Fifty classes of showing up for yourself.',  'classes', 50,  4),
  ('classes_100', 'One Hundred',      'A hundred classes. The studio is proud of you.', 'classes', 100, 5),
  ('streak_4',    'Four-Week Streak', 'A class every week for four weeks running.', 'streak',  4,   6),
  ('streak_8',    'Eight-Week Streak','Two months without missing a week.',         'streak',  8,   7),
  ('streak_12',   'Twelve-Week Streak','A full season of weekly classes.',          'streak',  12,  8)
on conflict (code) do nothing;

insert into public.perks (code, title, blurb, required_classes, sort) values
  ('free_class_25', 'Free class',      'Bring a friend or take a class on us. Show this at the front desk.', 25,  1),
  ('guest_pass_50', 'Guest pass',      'A class for a friend, any time.',                                   50,  2),
  ('gift_100',      'Studio gift',     'A thank-you gift from the studio. Pick it up at the front desk.',   100, 3)
on conflict (code) do nothing;
