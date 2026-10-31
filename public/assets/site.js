(function(){
  var C = window.GF_CONFIG || {}, S = window.GF_SCHEDULE || {week:{},events:[],closed:[]};
  var book = C.setmore || C.bookUrl;
  function $(s,r){return (r||document).querySelector(s)} function $$(s,r){return Array.prototype.slice.call((r||document).querySelectorAll(s))}
  function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]})}

  /* links from config */
  if(book) $$('[data-book]').forEach(function(a){a.href=book});
  if(C.buy) $$('[data-buy]').forEach(function(a){var u=C.buy[a.getAttribute('data-buy')]; if(u) a.href=u});
  if(C.email){ $$('[data-email]').forEach(function(a){var q=a.href.indexOf('?'); a.href='mailto:'+C.email+(q>-1?a.href.slice(q):''); if(!a.children.length) a.textContent=C.email});
               $$('[data-email-text]').forEach(function(e){e.textContent=C.email}); }

  /* dates in Arizona time */
  function az(){try{var p=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Phoenix",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date()).split("-");return new Date(+p[0],+p[1]-1,+p[2])}catch(e){var d=new Date();return new Date(d.getFullYear(),d.getMonth(),d.getDate())}}
  function iso(d){return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0")}
  function parse(k){var p=k.split("-");return new Date(+p[0],+p[1]-1,+p[2])}
  var T=az(), TK=iso(T), DN=["sun","mon","tue","wed","thu","fri","sat"], MN=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  $$('[data-year]').forEach(function(e){e.textContent=T.getFullYear()});
  function closed(k){return (S.closed||[]).indexOf(k)>-1}
  function evOn(k){return (S.events||[]).filter(function(e){return k>=e.d&&k<=e.end})}
  var upcoming=(S.events||[]).filter(function(e){return e.end>=TK}).sort(function(a,b){return a.d<b.d?-1:1});
  function when(e){var a=parse(e.d),b=parse(e.end);var w=DN[a.getDay()]+", "+MN[a.getMonth()]+" "+a.getDate();if(e.end!==e.d)w=DN[a.getDay()]+"–"+DN[b.getDay()]+", "+MN[a.getMonth()]+" "+a.getDate()+"–"+(b.getMonth()!==a.getMonth()?MN[b.getMonth()]+" ":"")+b.getDate();return w+(e.t?" · "+e.t:"")}
  function evCard(e){return '<article class="evc"><span class="pilltime">'+esc(when(e))+'</span><h3>'+esc(e.n)+'</h3><p>'+esc(e.more||e.s)+'</p>'+(e.link?'<p><a class="btn small" href="'+esc(e.link)+'" target="_blank" rel="noopener">'+esc(e.linkText||"learn more")+'</a></p>':'')+'</article>'}
  var STAR='<span class="star s1"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 0C11 7 13 9 20 10C13 11 11 13 10 20C9 13 7 11 0 10C7 9 9 7 10 0Z"/></svg></span>';

  /* home: today line + this week */
  var td=$('#today'); if(td){
    var h='<b>today</b>';
    if(closed(TK)) h+='<span>closed today, see you soon</span>';
    else { evOn(TK).forEach(function(e){h+='<span>'+esc((e.t?e.t+' ':'')+e.n)+'</span>'});
      var L=(S.week[T.getDay()]||[]); L.forEach(function(c){h+='<span>'+esc(c[0].replace(":00","")+' '+c[1])+'</span>'});
      if(!L.length&&!evOn(TK).length) h+='<span>rest day, see you tomorrow</span>'; }
    td.innerHTML=h;
  }
  var tw=$('#thisweek'); if(tw){
    var lim=iso(new Date(T.getFullYear(),T.getMonth(),T.getDate()+14));
    var soon=upcoming.filter(function(e){return e.d<=lim});
    if(soon.length) tw.innerHTML='<div class="card gold feature">'+STAR+'<p class="kicker">coming up at the studio</p><div class="evs">'+soon.map(evCard).join("")+'</div><p><a class="link-more" href="/events/">all events →</a></p></div>';
  }
  /* events page */
  var ec=$('#evcards'); if(ec) ec.innerHTML=upcoming.length?upcoming.map(evCard).join(""):'<div class="card soft center"><h3>new events coming soon</h3><p>Peek at our <a href="https://www.instagram.com/gilbertflexstudio/" target="_blank" rel="noopener">Instagram</a> for what\'s next.</p></div>';

  var el=$('#evlist'); if(el) el.innerHTML=upcoming.length?upcoming.map(function(e){return '<div class="cls ev"><time>'+esc(MN[parse(e.d).getMonth()]+' '+parse(e.d).getDate())+'</time><div><b>'+esc(e.n)+'</b><span>'+esc(e.s)+'</span></div></div>'}).join(""):'<p class="note">new events coming soon.</p>';

  /* book page: Setmore on the page once it's set */
  var be=$('#booking-embed'); if(be&&C.setmore){
    be.innerHTML='<iframe src="'+esc(C.setmore)+'" title="Book a class with Gilbert Flex Studio" loading="lazy" class="bookframe"></iframe>';
    var fb=$('#booking-fallback'); if(fb) fb.querySelector('h3').textContent='trouble seeing the booking calendar?';
  }

  /* contact form -> email app */
  var f=$('#cform'); if(f) f.addEventListener('submit',function(e){e.preventDefault();var d=new FormData(f);
    var body='Name: '+d.get('name')+'\nContact: '+d.get('contact')+'\n\n'+d.get('msg');
    location.href='mailto:'+(C.email||'')+'?subject='+encodeURIComponent('Website: '+d.get('subject'))+'&body='+encodeURIComponent(body)});
})();
