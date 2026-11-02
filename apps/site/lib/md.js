// Small, safe Markdown renderer shared by the site build (same rules as the staff Blog editor).
// Small, safe Markdown: everything is escaped first, then a few marks are turned into HTML.
// # Heading, ## Subheading, **bold**, *italic*, [link](https://…), ![photo](https://…), - lists, 1. lists, > quotes
export function md(src){
  const esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  const inline=s=>esc(s)
    .replace(/!\[([^\]]*)\]\((https:\/\/[^\s)]+)\)/g,'<img alt="$1" src="$2" loading="lazy">')
    .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+|\/[^\s)]*|#[^\s)]*|[a-z0-9.-]+\.html[^\s)]*)\)/gi,'<a href="$2">$1</a>')
    .replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g,'$1<em>$2</em>');
  const out=[];let para=[],list=null;
  const flushP=()=>{if(para.length){out.push('<p>'+para.map(inline).join('<br>')+'</p>');para=[]}};
  const flushL=()=>{if(list){out.push('<'+list.t+'>'+list.items.map(i=>'<li>'+inline(i)+'</li>').join('')+'</'+list.t+'>');list=null}};
  for(const raw of String(src||'').replace(/\r/g,'').split('\n')){
    const line=raw.trimEnd();let m;
    if(!line.trim()){flushP();flushL();continue}
    if((m=line.match(/^(#{1,3})\s+(.*)$/))){flushP();flushL();const n=m[1].length+1;out.push('<h'+n+'>'+inline(m[2])+'</h'+n+'>');continue}
    if((m=line.match(/^\s*[-*]\s+(.*)$/))){flushP();if(!list||list.t!=='ul'){flushL();list={t:'ul',items:[]}}list.items.push(m[1]);continue}
    if((m=line.match(/^\s*\d+[.)]\s+(.*)$/))){flushP();if(!list||list.t!=='ol'){flushL();list={t:'ol',items:[]}}list.items.push(m[1]);continue}
    if((m=line.match(/^>\s?(.*)$/))){flushP();flushL();out.push('<blockquote>'+inline(m[1])+'</blockquote>');continue}
    if((m=line.match(/^!\[([^\]]*)\]\((https:\/\/[^\s)]+)\)$/))){flushP();flushL();out.push('<figure>'+inline(line)+(m[1]?'<figcaption>'+esc(m[1])+'</figcaption>':'')+'</figure>');continue}
    flushL();para.push(line);
  }
  flushP();flushL();return out.join('\n');
}
