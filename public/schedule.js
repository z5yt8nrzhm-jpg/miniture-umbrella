/* =====================================================================
   SCHEDULE — update this file once a month. The home page, schedule
   page, events page and the /links page all read from it.
   week: 0 = Sunday ... 6 = Saturday.  ["time", "Class name", "short note"]
   events: d = start date, end = last date (YYYY-MM-DD), t = start time,
           n = name, s = one-line details, link = sign-up link (optional)
   closed: dates the studio is closed (YYYY-MM-DD)
   ===================================================================== */
window.GF_SCHEDULE = {
  week: {
    0: [["10:30 am","Beginner Yoga","new? start here"]],
    1: [["4:30 pm","Mindful Movement Monday","slow, gentle flow"],["6:00 pm","Prenatal Yoga","for mamas-to-be"],["7:00 pm","Gentle Restorative Yoga","props, blankets, melt"]],
    2: [["6:00 am","Sunrise Yoga","wake up slow"],["9:00 am","All Levels Yoga","a little of everything"],["5:00 pm","Mat Pilates","core + glow"],["6:00 pm","Yin Yoga","long, deep holds"],["6:00 pm","Intermediate Tantra","breath + energy work"]],
    3: [["6:00 pm","Prenatal Yoga","for mamas-to-be"],["6:00 pm","Beginner Gentle Restorative with Sound","with a sound bath"],["7:00 pm","Candlelight Yoga Nidra","guided deep rest"]],
    4: [["6:00 am","Sunrise Yoga","wake up slow"],["5:00 pm","Mat Pilates","core + glow"],["6:00 pm","Yin Yoga","long, deep holds"]],
    5: [],
    6: [["8:30 am","All Levels Yoga","a little of everything"],["9:00 am","Beginner Gentle Restorative with Sound","with a sound bath"],["10:00 am","Perinatal Yoga","for before + after baby"]]
  },
  events: [
    {d:"2026-11-06", end:"2026-11-08", t:"", n:"Sedona Retreat",
     s:"Nov 6–8 · off-site · Village of Oak Creek, Sedona",
     more:"Village of Oak Creek, Sedona · $450 per person · small group. Friday 2 pm to Sunday about 3:30 pm.",
     link:"https://illuminatepaths.com/sedona-retreat", linkText:"details + registration"}
  ],
  closed: []   /* no closures set. TeamUp lists a Thanksgiving Day class, so confirm before adding any */
};
