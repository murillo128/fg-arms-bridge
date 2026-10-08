/* Arms Bridge simulator UI. MIT. No external runtime dependencies or requests. */
(() => {
  'use strict';
  const A=globalThis.ArmsSimulator,$=id=>document.getElementById(id);
  const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const fmt=(n,d=2)=>Number.isFinite(n)?n.toLocaleString('es-ES',{minimumFractionDigits:d,maximumFractionDigits:d}):'∞';
  const pct=n=>fmt(100*n,Math.abs(100*n-Math.round(100*n))<1e-8?0:2)+' %';
  const sign=n=>(n>=0?'+':'−')+fmt(Math.abs(n),Number.isInteger(n)?0:2);
  const option=(v,t)=>`<option value="${esc(v)}">${esc(t)}</option>`;
  let state=A.clone(A.defaults),analysis=null,selected=15,activeTab='rolls',branch=false,timer=null,chainCount=1,chainFinal=10;
  const repo='https://github.com/murillo128/fg-arms-bridge';
  const numeric=['str','dex','proficiency','magic','attackOther','damageOther','attackTotal','damageTotal','criticalAt','defDex','armorMagic','shield','shieldMagic','defenseOther','cover','customBase'];
  const selects=['weapon','hands','ability','armor','customDex','profile'];
  const bools=['direct','open','cancelCritical'];
  function notice(text){$('message').textContent=text;}
  function readForm(){
    const next={};for(const id of numeric)next[id]=$(id).value;for(const id of selects)next[id]=$(id).value;for(const id of bools)next[id]=$(id).checked;
    next.mode=document.querySelector('[name=mode]:checked').value;
    next.extras=[...document.querySelectorAll('.extra-row')].map(row=>({dice:row.querySelector('[data-extra=dice]').value,type:row.querySelector('[data-extra=type]').value,crit:row.querySelector('[data-extra=crit]').checked}));
    for(const kind of ['resist','immune','vulnerable'])next[kind]=[...document.querySelectorAll(`[data-defense="${kind}"]:checked`)].map(e=>e.value);
    return next;
  }
  function extrasForm(){
    $('extras').innerHTML=state.extras.map((part,i)=>`<div class="extra-row"><input aria-label="Dados adicionales ${i+1}" data-extra="dice" type="text" maxlength="80" value="${esc(part.dice)}" placeholder="1d4"><select aria-label="Tipo de daño adicional ${i+1}" data-extra="type">${Object.entries(A.TYPES).map(([k,v])=>option(k,v)).join('')}</select><label class="check"><input data-extra="crit" type="checkbox" ${part.crit?'checked':''}> Dados en crítico</label><button class="remove" type="button" data-remove="${i}" aria-label="Quitar componente ${i+1}">×</button></div>`).join('');
    [...document.querySelectorAll('.extra-row')].forEach((row,i)=>{row.querySelector('[data-extra=type]').value=state.extras[i].type;});
    $('add-extra').disabled=state.extras.length>=6;
  }
  function constraints(){
    const w=A.DATA.weapons.find(w=>w.id===$('weapon').value);
    for(const opt of $('hands').options)opt.disabled=w.fixed_damage!==null?opt.value!=='1h':!w['dice_'+opt.value];
    if($('hands').selectedOptions[0]?.disabled)$('hands').value=w.dice_1h || w.fixed_damage!==null?'1h':'2h';
    const custom=['natural','manual'].includes($('armor').value);$('custom-armor').hidden=!custom;
    $('shieldMagic').disabled=$('shield').value==='0';
    for(const id of ['str','dex','proficiency','magic','attackOther','damageOther','ability'])$(id).disabled=$('direct').checked;
    $('attackTotal').disabled=$('damageTotal').disabled=!$('direct').checked;
  }
  function fillForm(){
    for(const id of numeric.concat(selects))$(id).value=state[id];for(const id of bools)$(id).checked=state[id];
    document.querySelector(`[name=mode][value="${state.mode}"]`).checked=true;
    for(const kind of ['resist','immune','vulnerable'])for(const e of document.querySelectorAll(`[data-defense="${kind}"]`))e.checked=state[kind].includes(e.value);
    extrasForm();constraints();calculate();
  }
  function calculate(){
    try {constraints();const next=A.validate(readForm());const value=A.analyze(next);state=next;analysis=value;$('error').hidden=true;$('results').hidden=false;render();}
    catch(e){$('error').textContent=e.message;$('error').hidden=false;$('results').hidden=true;}
  }
  function defendChips(){
    for(const kind of ['resist','immune','vulnerable'])$('chips-'+kind).innerHTML=state[kind].length?state[kind].map(t=>`<span class="chip">${esc(A.TYPES[t])}</span>`).join(''):'<span class="chip empty">Ninguna</span>';
  }
  function headerStats(){
    const {d}=analysis;const type=A.TYPES[d.w.damage_type].toLowerCase();
    $('weapon-note').textContent=A.GROUPS[d.w.group]+' / '+(d.w.origin==='dnd2024'?(d.w.category==='simple'?'Simple':'Marcial'):'Campaña')+' / '+d.w.mastery;
    $('attack-formula').innerHTML=`<span><span class="key">ATAQUE</span><b>${sign(d.attack)}</b></span><em>${state.direct?'Bono total manual':`${d.ability==='str'?'FUE':'DES'} ${sign(d.abilityMod)} · competencia ${sign(state.proficiency)} · magia ${sign(state.magic)}`}</em><span class="divider"></span><span><span class="key">DAÑO BASE</span><b>${esc(d.w['dice_'+state.hands] || d.w.fixed_damage)} ${sign(d.damage)}</b></span><em>${type}</em>`;
    $('defense-formula').innerHTML=`<span><span class="key">CA D&D</span><b>${fmt(d.ac,0)}</b></span><em>${d.base} + defensa ${sign(d.defense)}</em><span class="divider"></span><span><span class="key">DEFENSA ADICIONAL</span><b>${sign(d.defense)}</b></span><em>${esc(A.DATA.profiles.find(p=>p.id===d.profile).label)}</em>`;
    $('dex-note').textContent=`Destreza aplicada: ${sign(d.dexApplied)}. ${d.a.category==='Pesada'?'La armadura pesada no aplica Destreza.':d.a.category==='Media'?'La armadura media limita el bono a +2.':'Según la fórmula elegida.'}`;
    const warnings=[];
    if(d.w.origin!=='dnd2024')warnings.push('Perfil de campaña: no es un arma oficial de las reglas básicas 2024.');
    if(d.w.id==='lance' && state.hands==='1h')warnings.push('Este uso a una mano requiere estar montado.');
    if(d.w.fixed_damage!==null)warnings.push('Daño fijo: no añade característica ni suplemento abierto en Arms Bridge 0.3.1.');
    if(d.w.properties.includes('heavy') && ((d.w.properties.includes('ammunition')?state.dex:state.str)<13) && !state.direct)warnings.push('Arma pesada con característica inferior a 13: aplica desventaja según la regla; selecciona el modo correspondiente.');
    $('weapon-warning').textContent=warnings.join(' ');$('weapon-warning').hidden=!warnings.length;
    defendChips();
    const a=analysis.sums.old,b=analysis.sums.bridge,relative=a.mean?100*(b.mean/a.mean-1):null;
    const cards=[['Daño esperado por intento · incluidos los fallos',fmt(a.mean),fmt(b.mean),relative===null?'':`<span class="delta ${relative>=0?'positive':''}">${sign(relative)} %</span>`],['Probabilidad de impacto',pct(a.hit),pct(b.hit),''],['Probabilidad de crítico',pct(a.crit),pct(b.crit),''],['Máximo posible por intento',fmt(a.max,0),fmt(b.max,0),b.max===Infinity?'<small>cola abierta</small>':'']];
    $('metrics').innerHTML=cards.map(([label,x,y,note])=>`<div class="metric"><label>${label}</label><div class="metric-value"><span class="old">${x}</span><span class="arrow">→</span><span class="new">${y}</span>${note}</div></div>`).join('');
  }
  function chartLimit(a,b){return Math.max(1,A.percentile(a.pmf,.999),A.percentile(b.pmf,.999));}
  function buckets(out,limit,count){
    const width=Math.max(1,Math.ceil((limit+1)/(count-1))),cut=width*(count-1),bins=Array(count).fill(0);
    for(const [n,p]of out.pmf)bins[Math.min(count-1,Math.floor(n/width))]+=p;
    bins[count-1]+=out.tailProbability||0;
    return {bins,width,cut};
  }
  function spark(out,color,limit){
    const {bins}=buckets(out,limit,36),top=Math.max(...bins,0.0001);
    return `<svg class="spark" viewBox="0 0 108 24" aria-hidden="true"><path d="M0 23H108" stroke="#dfd9ce" fill="none"/>${bins.map((p,i)=>p?`<rect x="${i*3}" y="${23-21*p/top}" width="2" height="${21*p/top}" fill="${color}" opacity=".78"/>`:'').join('')}</svg>`;
  }
  function fullChart(a,b,wide=false){
    const limit=chartLimit(a,b),n=Math.min(42,limit+2),aa=buckets(a,limit,n),bb=buckets(b,limit,n),top=Math.max(.05,Math.ceil(Math.max(...aa.bins,...bb.bins)*10)/10);
    const W=wide?700:280,H=wide?285:210,left=wide?38:28,right=10,bottom=34,t=16,pw=W-left-right,ph=H-t-bottom,bw=pw/n;
    let svg=`<svg class="chart" role="img" aria-label="Distribución del daño. D&D en burdeos y Arms Bridge en verde. Las barras finales agrupan la cola." viewBox="0 0 ${W} ${H}">`;
    for(let i=0;i<=4;i++){const y=t+ph-ph*i/4;svg+=`<path class="grid" d="M${left} ${y}H${W-right}"/><text x="${left-7}" y="${y+3}" text-anchor="end">${fmt(top*100*i/4,0)}%</text>`;}
    for(let i=0;i<n;i++) {
      const x=left+i*bw;
      for(const [p,c,j]of [[aa.bins[i],'#993d49',0],[bb.bins[i],'#21776d',1]])if(p>0)svg+=`<rect x="${x+bw*(.08+.45*j)}" y="${t+ph-ph*p/top}" width="${bw*.37}" height="${ph*p/top}" fill="${c}"><title>${i===n-1?'≥':''}${i*aa.width} puntos: ${fmt(p*100,4)} %</title></rect>`;
      if(i===n-1 || i%Math.max(1,Math.ceil(n/7))===0)svg+=`<text x="${x+bw/2}" y="${H-20}" text-anchor="middle">${i===n-1?'≥':''}${i*aa.width}</text>`;
    }
    svg+=`<text x="${W/2}" y="${H-3}" text-anchor="middle">Daño en puntos · probabilidad en %</text></svg>`;
    const residual=Math.max(a.tailProbability||0,b.tailProbability||0);
    return '<div class="legend"><span>D&D 2024</span><span>Arms Bridge</span></div>'+svg+`<p class="chart-caption">Misma escala. La última barra agrupa los valores ≥${aa.cut}${aa.width>1?`; intervalos de ${aa.width} puntos`:''}. ${residual?`La gráfica enumera las continuaciones hasta dejar ${residual.toExponential(2)} de probabilidad residual; la media incluye también esa cola analíticamente.`:'Distribución calculada, sin muestreo aleatorio.'}</p>`;
  }
  function renderRows(){
    const limit=Math.max(...analysis.rows.flatMap(row=>[A.percentile(row.old.pmf,.995),A.percentile(row.bridge.pmf,.995)]),1);
    $('rows').innerHTML=analysis.rows.map(({r,p,old:a,bridge:b})=>`<tr data-roll="${r}" class="${r===selected?'selected ':''}${r>=state.criticalAt?'critical ':''}${!a.hit && !b.hit?'miss':''}"><td><button type="button" class="roll-button" aria-pressed="${r===selected}" aria-label="Inspeccionar tirada ${r}">${String(r).padStart(2,'0')}${r===20?`<span>${state.open?'abierto':'crítico'}</span>`:''}</button></td><td class="prob">${pct(p)}</td><td>${fmt(a.min,0)}</td><td class="average old">${fmt(a.mean)}</td><td>${fmt(a.max,0)}</td><td>${spark(a,'#993d49',limit)}</td><td>${fmt(b.min,0)}</td><td class="average new">${fmt(b.mean)}</td><td>${fmt(b.max,0)}</td><td>${spark(b,'#21776d',limit)}</td><td class="${b.mean>a.mean?'new':b.mean<a.mean?'old':''}">${b.mean===a.mean?'—':sign(b.mean-a.mean)}</td></tr>`).join('');
  }
  function statBoxes(a,b){return `<div class="detail-stats"><div class="stat-box"><label>MEDIA D&D</label><strong class="old">${fmt(a.mean)}</strong><small>Mín. ${fmt(a.min,0)} · Máx. ${fmt(a.max,0)}</small></div><div class="stat-box"><label>MEDIA ARMS BRIDGE</label><strong class="new">${fmt(b.mean)}</strong><small>Mín. ${fmt(b.min,0)} · Máx. ${fmt(b.max,0)}</small></div></div>`;}
  function renderDetail(){
    const row=analysis.rows[selected-1],d=analysis.d;
    let b=row.bridge,chainInfo='';
    if(selected===20 && state.open){
      if(branch)b=A.chain(state,chainCount,chainFinal);
      chainInfo=`<div class="chain-fields"><label class="check"><input id="branch" type="checkbox" ${branch?'checked':''}> Inspeccionar una cadena concreta</label>${branch?`<div class="fields"><label>Veintes consecutivos<input id="chain-count" type="number" min="1" max="10000" value="${chainCount}"></label><label>Dado final (1–19)<input id="chain-final" type="number" min="1" max="19" value="${chainFinal}"></label></div><p>${chainCount<=4?Array(chainCount).fill('20').join(' + '):'20 × '+chainCount} + ${chainFinal} = ${20*chainCount+chainFinal}<br>Suplemento ${sign(b.supplement)} ${A.TYPES[d.w.damage_type].toLowerCase()}.<br>Probabilidad por intento: ${(row.p*Math.pow(20,-chainCount)).toExponential(3)}.</p>`:'<p>Mezcla de todas las cadenas que comienzan con 20. Los dados críticos y los componentes adicionales conservan su distribución.</p>'}</div>`;
    }
    const index=b.lookup?.index;
    const components=b.components||[];
    const detailExplanation=!b.hit?'La tabla no produce impacto: no se aplica el daño adicional.':b.crit?'El crítico utiliza los dados nativos de D&D. El suplemento físico se añade una sola vez.':d.pool.faces.length?'La tabla fija el valor de los dados físicos base. Los componentes adicionales mantienen su distribución.':'Esta arma conserva su daño fijo nativo.';
    $('detail').innerHTML=`<div class="detail-title"><p>TIRADA SELECCIONADA · ${pct(row.p)}</p><div><strong>${selected}</strong><span class="help">${sign(d.attack)} = ${selected+d.attack} al ataque</span></div><p class="equation">${index!==undefined?`Índice: 5 × (${branch && selected===20?20*chainCount+chainFinal:selected} ${sign(d.attack)} − (${sign(d.defense)})) = ${index}`:'20 inicial + todas sus continuaciones abiertas'}${b.lookup && b.hit && !b.crit?`<br>Calidad del golpe: ${fmt(b.lookup.quality*100,0)} %`:''}</p></div><div class="detail-body">${chainInfo}<h3>Distribución del daño aplicado</h3>${fullChart(row.old,b)}${statBoxes(row.old,b)}<div class="breakdown"><h3>Arms Bridge · desglose por tipo</h3>${components.map(c=>`<div class="component"><span>${esc(A.TYPES[c.type])}</span><b>${c.applied.min===c.applied.max?fmt(c.applied.min,0):fmt(c.applied.min,0)+'–'+fmt(c.applied.max,0)}</b><small>Antes: ${fmt(c.raw.mean)} de media · después: ${fmt(c.applied.mean)}${state.immune.includes(c.type)?' · inmune':state.resist.includes(c.type)?' · resistencia':''}${state.vulnerable.includes(c.type)?' · vulnerable':''}</small></div>`).join('')}<p class="help">${detailExplanation}${selected===20 && state.open && !branch?' Activa una cadena concreta para ver el desglose.':''}</p></div></div>`;
  }
  function renderTab(){
    if(activeTab==='global'){$('global-chart').innerHTML=fullChart(analysis.sums.old,analysis.sums.bridge,true);$('global-stats').innerHTML=statBoxes(analysis.sums.old,analysis.sums.bridge)+`<p class="help">Daño medio condicionado a impactar: ${fmt(analysis.sums.old.onHit)} en D&D y ${fmt(analysis.sums.bridge.onHit)} en Arms Bridge.</p>`;}
    if(activeTab==='sensitivity'){
      const vals=[];for(let i=-5;i<=5;i++){const bonus=analysis.d.attack+i;if(bonus< -30 || bonus>50)continue;const a=A.analyze({...state,direct:true,attackTotal:bonus,damageTotal:analysis.d.damage});vals.push([bonus,a.sums.old.mean,a.sums.bridge.mean]);}
      const max=Math.max(...vals.flatMap(x=>x.slice(1)),1),W=650,H=260,l=40,bottom=30,ph=H-bottom-10,pw=W-l-20;
      const x=i=>l+pw*i/Math.max(1,vals.length-1),y=v=>H-bottom-v/max*ph;
      let svg=`<svg class="chart" role="img" aria-label="Daño medio por intento según el bono al ataque" viewBox="0 0 ${W} ${H}">`;
      for(let j=0;j<=4;j++){const v=j*max/4;svg+=`<path class="grid" d="M${l} ${y(v)}H${W-20}"/><text x="${l-7}" y="${y(v)+3}" text-anchor="end">${fmt(v,1)}</text>`;}
      for(const [k,color]of [[1,'#993d49'],[2,'#21776d']]){svg+=`<polyline fill="none" stroke="${color}" stroke-width="2.5" points="${vals.map((v,i)=>`${x(i)},${y(v[k])}`).join(' ')}"/>`;vals.forEach((v,i)=>{svg+=`<circle cx="${x(i)}" cy="${y(v[k])}" r="3" fill="${color}"/>`;});}
      vals.forEach((v,i)=>{svg+=`<text x="${x(i)}" y="${H-9}" text-anchor="middle">${sign(v[0])}</text>`;});svg+='</svg>';
      $('sensitivity-chart').innerHTML='<div class="legend"><span>D&D 2024</span><span>Arms Bridge</span></div>'+svg+'<table class="sensitivity-table"><thead><tr><th>Bono</th><th>Media D&D</th><th>Media Arms Bridge</th></tr></thead><tbody>'+vals.map(v=>`<tr><td>${sign(v[0])}</td><td class="old">${fmt(v[1])}</td><td class="new">${fmt(v[2])}</td></tr>`).join('')+'</tbody></table>';
    }
  }
  function render(){headerStats();renderRows();renderDetail();renderTab();}
  function showModal(title,body){$('modal-title').textContent=title;$('modal-body').innerHTML=body;$('modal').showModal();}
  const rules=()=>showModal('Las reglas, a la vista.',`<div class="dialog-content"><p>La comparación utiliza las reglas básicas de <b>D&D 2024</b> y las curvas experimentales de <b>Arms Bridge ${A.DATA.version}</b>. No lanza dados: calcula sus distribuciones.</p><h3>1. Un ataque, veinte resultados</h3><p>Un 1 natural falla; el umbral crítico seleccionado determina los críticos. El arma suma característica, competencia y bonos. La Destreza se aplica completa con armadura ligera, hasta +2 con media y no se aplica con pesada. Ventaja y desventaja cambian el peso de cada resultado, no se añaden como un bono numérico. Los umbrales 18 o 19 requieren un rasgo específico.</p><h3>2. La tabla cambia el daño físico</h3><p>La consulta usa <b>5 × (suma abierta + ataque − defensa adicional)</b>. La protección elige una columna; defensa adicional = CA − CA material. Un impacto ordinario selecciona un percentil exacto de los dados base. Los dados de crítico permanecen nativos. El exceso sobre la última fila añade <b>floor(media de dados base × exceso / 10)</b>, donde el exceso se mide en puntos de d20.</p><h3>3. Cada tipo se resuelve por separado</h3><p>Se agrupan todos los componentes del mismo tipo antes de aplicar sus defensas. La inmunidad anula ese tipo. La resistencia divide entre dos, redondeando hacia abajo; después se aplica vulnerabilidad. Nunca se divide la media en lugar de calcular la media del daño redondeado. La casilla de cada componente indica si sus dados se duplican con un crítico; sus constantes no se duplican.</p><h3>4. El 20 está realmente abierto</h3><p>Solo el 20 inicial seleccionado abre. Cada continuación es un d20 simple: 20 suma y continúa; 1–19 suma y termina. Se calcula la esperanza de toda la cola geométrica, sin imponer un máximo de juego. Las gráficas enumeran un prefijo y agrupan la probabilidad residual en la última barra. La media incorpora analíticamente los términos no dibujados. Si el componente físico es inmune, o el arma tiene daño fijo, el máximo aplicado puede ser finito.</p><h3>5. Lo que este laboratorio no presupone</h3><p>No ejecuta maestrías, dotes, repeticiones especiales de dados, salvaciones, estados ni ataques posteriores. «Pesada» muestra una advertencia cuando falta la característica requerida; selecciona entonces la desventaja apropiada. Las defensas condicionales se seleccionan manualmente para el ataque concreto. No deduce resistencias del material ni de un nombre de criatura. El modo personalizado permite introducir la fórmula defensiva de tu caso. Activar varias fuentes de ventaja y desventaja se resuelve eligiendo su modo neto.</p><p>La agrupación de armaduras aún no diferencia siempre CA 17 y CA 18 dentro de una misma columna. Algunas familias comparten curvas. Shuriken y trabuco son propuestas de campaña. El objetivo es hacer visibles esas diferencias y limitaciones, no presentar la alpha como equilibrada.</p><h3>Fuentes y privacidad</h3><p><a href="https://www.dndbeyond.com/sources/dnd/br-2024/equipment" target="_blank" rel="noopener">D&D 2024 · Equipo</a> · <a href="https://www.dndbeyond.com/sources/dnd/br-2024/playing-the-game" target="_blank" rel="noopener">Daño, críticos y resistencias</a> · <a href="${repo}/blob/main/extension/scripts/arms_engine.lua" target="_blank" rel="noopener">Motor Lua</a> · <a href="${repo}/blob/main/docs/SIMULATOR.md" target="_blank" rel="noopener">Método y pruebas</a>.</p><p>No hay analítica, cuentas ni llamadas a servicios. Guardar usa el almacenamiento local del navegador; compartir incluye los parámetros del escenario en el fragmento de la URL. El logo procede del material del manual, sin atribuir afiliación a ICE. El código conserva la licencia MIT del proyecto.</p></div>`);
  function selectRow(n){selected=n;branch=false;renderRows();renderDetail();}
  function armory(){showModal('Armería · 40 formas de empezar',`<label>Buscar por nombre o grupo<input id="armory-search" type="text" placeholder="Espada, maza, arco…" maxlength="60"></label><div class="armory-list" id="armory-list"></div>`);renderArmory('');$('armory-search').addEventListener('input',e=>renderArmory(e.target.value));}
  function renderArmory(query){const norm=s=>s.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();$('armory-list').innerHTML=A.DATA.weapons.filter(w=>norm(w.name_es+' '+w.name_en+' '+A.GROUPS[w.group]).includes(norm(query))).map(w=>`<button class="armory-item" data-choose="${w.id}" type="button"><strong>${esc(w.name_es)}</strong><span>${esc(A.GROUPS[w.group])} · ${esc(w.dice_1h || w.dice_2h || w.fixed_damage)}${w.dice_1h && w.dice_2h?' / '+w.dice_2h:''} · ${esc(A.TYPES[w.damage_type])}${w.origin!=='dnd2024'?' · campaña':''}</span></button>`).join('') || '<p>No se encuentran armas con ese nombre.</p>';}
  function hydrate(hash){try{state=A.decode(hash);fillForm();notice('Escenario cargado desde el enlace.');}catch(e){notice('No se ha cargado el enlace: '+e.message);}}
  function downloadCSV(){if(!analysis)return;const quote=s=>'"'+String(s).replace(/"/g,'""')+'"';const header=['d20','probabilidad','dnd_min','dnd_media','dnd_max','bridge_min','bridge_media','bridge_max','delta_media'];const rows=analysis.rows.map(r=>[r.r,r.p,r.old.min,r.old.mean,r.old.max,r.bridge.min,r.bridge.mean,r.bridge.max,r.bridge.mean-r.old.mean]);const text='\uFEFF'+[header,...rows].map(r=>r.map(quote).join(';')).join('\r\n');const url=URL.createObjectURL(new Blob([text],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=`arms-bridge-${state.weapon}.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(url),2000);}
  $('weapon').innerHTML=Object.entries(A.GROUPS).map(([id,label])=>`<optgroup label="${label}">${A.DATA.weapons.filter(w=>w.group===id).map(w=>option(w.id,w.name_es+(w.origin!=='dnd2024'?' · campaña':''))).join('')}</optgroup>`).join('');
  $('armor').innerHTML=A.ARMORS.map(a=>option(a.id,a.label+(a.id==='natural' || a.id==='manual'?'':` · CA base ${a.base}`))).join('');
  $('profile').innerHTML=A.DATA.profiles.map(p=>option(p.id,p.label)).join('');
  $('defenses').innerHTML=[['resist','Resistencias'],['immune','Inmunidades'],['vulnerable','Vulnerabilidades']].map(([kind,label])=>`<details><summary>${label}<span id="chips-${kind}" class="chips"></span></summary><div class="defense-options">${Object.entries(A.TYPES).map(([key,name])=>`<label><input type="checkbox" data-defense="${kind}" value="${key}">${name}</label>`).join('')}</div></details>`).join('');
  $('config').addEventListener('submit',e=>e.preventDefault());
  $('config').addEventListener('input',()=>{clearTimeout(timer);timer=setTimeout(calculate,100);});
  $('config').addEventListener('change',e=>{clearTimeout(timer);if(e.target.id==='armor')$('profile').value=A.ARMORS.find(a=>a.id===e.target.value).profile;calculate();});
  $('extras').addEventListener('click',e=>{const b=e.target.closest('[data-remove]');if(b){const next=readForm();next.extras.splice(Number(b.dataset.remove),1);state={...state,extras:next.extras};extrasForm();calculate();}});
  $('add-extra').addEventListener('click',()=>{if(state.extras.length>=6)return;const next=readForm();state={...state,extras:next.extras.concat({dice:'1d4',type:'acid',crit:true})};extrasForm();calculate();});
  $('rows').addEventListener('click',e=>{const row=e.target.closest('[data-roll]');if(row)selectRow(Number(row.dataset.roll));});
  $('rows').addEventListener('keydown',e=>{if(['ArrowUp','ArrowDown'].includes(e.key)){e.preventDefault();selectRow(Math.max(1,Math.min(20,selected+(e.key==='ArrowUp'?-1:1))));document.querySelector(`[data-roll="${selected}"] button`).focus();}});
  document.querySelectorAll('[data-tab]').forEach(b=>b.addEventListener('click',()=>{activeTab=b.dataset.tab;document.querySelectorAll('[data-tab]').forEach(t=>{t.setAttribute('aria-selected',String(t.dataset.tab===activeTab));$('view-'+t.dataset.tab).hidden=t.dataset.tab!==activeTab;});renderTab();}));
  $('detail').addEventListener('change',e=>{if(e.target.id==='branch'){branch=e.target.checked;renderDetail();}else if(e.target.id==='chain-count' || e.target.id==='chain-final'){const n=Number($('chain-count').value),j=Number($('chain-final').value);try{A.chain(state,n,j);chainCount=n;chainFinal=j;renderDetail();}catch(error){notice(error.message);}}});
  $('explore').addEventListener('click',()=>{selectRow(20);if(innerWidth<900)$('detail').scrollIntoView({block:'start',behavior:'smooth'});});
  $('reset').addEventListener('click',()=>{state=A.clone(A.defaults);selected=15;branch=false;fillForm();try{history.replaceState(null,'',location.pathname+location.search);}catch(_){}notice('Escenario inicial restablecido. El escenario guardado se conserva.');});
  $('save').addEventListener('click',()=>{try{const s=A.validate(readForm());localStorage.setItem('arms-bridge.scenario.v1',JSON.stringify(s));notice('Escenario guardado en este navegador.');}catch(e){notice('No se pudo guardar: '+e.message);}});
  $('load').addEventListener('click',()=>{try{const s=localStorage.getItem('arms-bridge.scenario.v1');if(!s){notice('Todavía no hay un escenario guardado en este navegador.');return;}state=A.validate(JSON.parse(s));fillForm();notice('Escenario guardado cargado.');}catch(e){notice('No se pudo abrir: '+e.message);}});
  $('share').addEventListener('click',async()=>{try{const hash=A.encode(readForm()),url=location.href.split('#')[0]+hash;try{await navigator.clipboard.writeText(url);notice('Enlace copiado. Incluye todos los parámetros del escenario.');}catch(_){showModal('Compartir escenario',`<p>Este enlace contiene la configuración, sin enviar datos a un servidor.</p><label>Enlace para copiar<input type="text" readonly value="${esc(url)}" id="share-url"></label>`);$('share-url').select();}}catch(e){notice(e.message);}});
  $('csv').addEventListener('click',downloadCSV);$('armory').addEventListener('click',armory);for(const id of ['rules','method'])$(id).addEventListener('click',rules);
  $('close-modal').addEventListener('click',()=>$('modal').close());
  $('modal-body').addEventListener('click',e=>{const b=e.target.closest('[data-choose]');if(b){$('weapon').value=b.dataset.choose;constraints();calculate();$('modal').close();}});
  addEventListener('hashchange',()=>{if(location.hash.startsWith('#s='))hydrate(location.hash);});
  fillForm();if(location.hash.startsWith('#s='))hydrate(location.hash);
})();
