/* Arms Bridge browser comparator. MIT. Original experimental rules, not ICE tables.
   No sampling: discrete convolution, exact integer quantiles, analytic open tail. */
(function(root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./data.js'));
  else root.ArmsSimulator = factory(root.ARMS_DATA);
})(globalThis, function(DATA) {
  'use strict';
  const TYPES = {bludgeoning:'Contundente',piercing:'Perforante',slashing:'Cortante',acid:'Ácido',cold:'Frío',fire:'Fuego',force:'Fuerza',lightning:'Relámpago',necrotic:'Necrótico',poison:'Veneno',psychic:'Psíquico',radiant:'Radiante',thunder:'Trueno'};
  const GROUPS = {blunted:'Contundentes',bladed:'Hojas',axes:'Hachas',polearms:'Armas de asta',bows:'Arcos',crossbows:'Ballestas',exotic:'Exóticas',firearms:'Armas de fuego'};
  // dexCap=null means no cap; 0 for heavy armor means NO Dexterity, even negative.
  const ARMORS = [
    ['unarmored','Sin armadura',10,null,'unarmored','Sin armadura'],
    ['padded','Acolchada',11,null,'leather','Ligera'],['leather','Cuero',11,null,'leather','Ligera'],['studded','Cuero tachonado',12,null,'leather','Ligera'],
    ['hide','Pieles',12,2,'leather','Media'],['chainshirt','Camisa de malla',13,2,'mail','Media'],['scale','Cota de escamas',14,2,'mail','Media'],['breastplate','Coraza',14,2,'plate','Media'],['halfplate','Semiplacas',15,2,'plate','Media'],
    ['ring','Cota de anillas',14,0,'mail','Pesada'],['chain','Cota de malla',16,0,'mail','Pesada'],['splint','Laminada',17,0,'plate','Pesada'],['plate','Placas completas',18,0,'plate','Pesada'],
    ['natural','Armadura natural',15,0,'natural_scales','Natural'],['manual','Defensa personalizada',10,null,'unarmored','Manual']
  ].map(([id,label,base,dexCap,profile,category]) => ({id,label,base,dexCap,profile,category}));
  const defaults = {
    weapon:'longsword',hands:'1h',str:16,dex:14,ability:'auto',proficiency:3,magic:1,attackOther:0,damageOther:0,
    direct:false,attackTotal:7,damageTotal:4,criticalAt:20,cancelCritical:false,
    armor:'halfplate',defDex:14,armorMagic:0,shield:0,shieldMagic:0,defenseOther:0,cover:0,
    customBase:15,customDex:'none',profile:'plate',mode:'normal',open:true,
    extras:[{dice:'1d4',type:'fire',crit:true}],resist:['fire'],immune:[],vulnerable:[]
  };
  const clone = x => JSON.parse(JSON.stringify(x));
  const mod = n => Math.floor((n-10)/2);
  function number(value, min, max, label) {
    if (value === '' || value === null || typeof value === 'boolean' || !Number.isInteger(Number(value)) || Number(value)<min || Number(value)>max)
      throw new Error(label + ': introduce un entero entre ' + min + ' y ' + max + '.');
    return Number(value);
  }
  function choice(v, values, label) { if (!values.includes(v)) throw new Error(label + ' no válido.'); return v; }
  function validate(input) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Escenario no válido.');
    const s = clone(defaults);
    for (const [key,min,max] of [['str',1,30],['dex',1,30],['defDex',1,30],['proficiency',0,6],['magic',0,3],['armorMagic',0,3],['shield',0,2],['shieldMagic',0,3],['attackOther',-30,30],['damageOther',-100,100],['attackTotal',-30,50],['damageTotal',-100,100],['defenseOther',-30,30],['customBase',0,50]])
      s[key]=number(input[key] ?? s[key],min,max,key);
    for (const key of ['direct','open','cancelCritical']) { if (input[key] !== undefined && typeof input[key] !== 'boolean') throw new Error(key+': valor no válido.'); s[key]=input[key] ?? s[key]; }
    s.weapon=choice(input.weapon ?? s.weapon, DATA.weapons.map(w=>w.id),'Arma');
    s.hands=choice(input.hands ?? s.hands,['1h','2h'],'Empuñadura');
    s.armor=choice(input.armor ?? s.armor,ARMORS.map(a=>a.id),'Armadura');
    s.profile=choice(input.profile ?? s.profile,DATA.profiles.map(a=>a.id),'Perfil');
    s.ability=choice(input.ability ?? s.ability,['auto','str','dex'],'Característica');
    s.customDex=choice(input.customDex ?? s.customDex,['none','full','cap2'],'Destreza natural/manual');
    s.mode=choice(input.mode ?? s.mode,['normal','advantage','disadvantage'],'Modo');
    s.criticalAt=choice(Number(input.criticalAt ?? s.criticalAt),[18,19,20],'Umbral crítico');
    s.cover=choice(Number(input.cover ?? s.cover),[0,2,5],'Cobertura');
    for (const key of ['resist','immune','vulnerable']) {
      const arr=input[key] ?? s[key];
      if (!Array.isArray(arr) || arr.length>13 || arr.some(t=>!Object.hasOwn(TYPES,t))) throw new Error('Tipos de defensa no válidos.');
      s[key]=[...new Set(arr)];
    }
    const extras=input.extras ?? s.extras;
    if (!Array.isArray(extras) || extras.length>6) throw new Error('Se admiten hasta seis componentes adicionales.');
    s.extras=extras.map(x=>{
      if(!x || typeof x.dice!=='string' || !Object.hasOwn(TYPES,x.type) || typeof x.crit!=='boolean') throw new Error('Componente de daño no válido.');
      parseDice(x.dice); return {dice:x.dice,type:x.type,crit:x.crit};
    });
    const weapon=DATA.weapons.find(w=>w.id===s.weapon);
    if (!weapon['dice_'+s.hands] && weapon.fixed_damage === null) throw new Error('Ese uso no está definido para el arma.');
    const all=[weapon['dice_'+s.hands] || String(weapon.fixed_damage),...s.extras.map(x=>x.dice)].map(parseDice);
    if (all.reduce((n,p)=>n+p.faces.reduce((a,b)=>a+b,0),0)>500) throw new Error('Límite de cálculo: 500 caras sumadas por ataque (antes de crítico).');
    return s;
  }
  // Parse only additive positive dice and signed constants; never eval user text.
  function parseDice(expression) {
    if (typeof expression!=='string' || expression.length>80) throw new Error('Daño: usa una expresión como 2d6+3.');
    const s=expression.replace(/\s/g,'').toLowerCase();
    if (!/^[+-]?(?:\d*d\d+|\d+)(?:[+-](?:\d*d\d+|\d+))*$/.test(s)) throw new Error('Daño no válido: usa, por ejemplo, 1d4, 2d6+3 o 2d6+1d4.');
    let flat=0,faces=[];
    for (const term of s.match(/[+-]?[^+-]+/g)) {
      if (term.includes('d')) {
        if (term[0]==='-') throw new Error('No se admiten dados negativos.');
        const [n,die]=term.replace(/^\+/,'').split('d');
        const count=number(n || 1,1,16,'Número de dados'), sides=number(die,2,100,'Caras');
        faces.push(...Array(count).fill(sides));
      } else flat+=Number(term);
    }
    if (faces.length>16 || faces.reduce((a,b)=>a+b,0)>500 || Math.abs(flat)>100) throw new Error('Daño demasiado grande: máximo 16 dados, 500 caras sumadas y modificador ±100.');
    return {faces,flat};
  }
  const diceCache=new Map();
  function diceCounts(faces) {
    const key=faces.slice().sort((a,b)=>a-b).join(',');
    if (diceCache.has(key)) return diceCache.get(key);
    let counts=[1n],total=1n;
    for(const sides of faces) {
      const next=Array(counts.length+sides).fill(0n);
      for(let i=0;i<counts.length;i++) if(counts[i]) for(let d=1;d<=sides;d++) next[i+d]+=counts[i];
      counts=next;total*=BigInt(sides);
    }
    const result={counts,total};
    if(diceCache.size>80) diceCache.clear(); diceCache.set(key,result);return result;
  }
  function quantile(faces,q) {
    const {counts,total}=diceCounts(faces);
    // All shipped qualities are hundredths: compare exact counts, not rounded CDFs.
    const numerator=BigInt(Math.round(q*100)),denominator=100n;
    let sum=0n;
    for(let i=0;i<counts.length;i++) {sum+=counts[i];if(counts[i]>0n && sum*denominator>=total*numerator)return i;}
    return counts.length-1;
  }
  const point=x=>new Map([[x,1]]);
  function add(map,x,p) {map.set(x,(map.get(x)||0)+p);}
  function convolve(a,b) {const out=new Map();for(const [x,p] of a)for(const [y,q] of b)add(out,x+y,p*q);return out;}
  function dicePMF(faces,flat=0) {
    const {counts,total}=diceCounts(faces),out=new Map(),den=Number(total);
    counts.forEach((n,i)=>{if(n)out.set(i+flat,Number(n)/den);});return out;
  }
  function transform(pmf,fn) {const out=new Map();for(const [x,p] of pmf)add(out,fn(x),p);return out;}
  function stats(pmf) {let min=Infinity,max=-Infinity,mean=0,mass=0;for(const [d,p]of pmf){if(p>0){min=Math.min(min,d);max=Math.max(max,d);mean+=d*p;mass+=p;}}return {min,max,mean,mass};}
  function weight(r,mode) {return mode==='advantage'?(2*r-1)/400:mode==='disadvantage'?(41-2*r)/400:1/20;}
  function defense(value,type,s) {
    let n=Math.max(0,value);
    if(s.immune.includes(type))return 0;
    if(s.resist.includes(type))n=Math.floor(n/2);
    if(s.vulnerable.includes(type))n*=2;
    return n;
  }
  function derive(s) {
    const w=DATA.weapons.find(w=>w.id===s.weapon),a=ARMORS.find(a=>a.id===s.armor);
    const ranged=w.properties.includes('ammunition') || w.id==='dart' || w.id==='shuriken';
    const ability=s.ability==='auto'?(w.properties.includes('finesse')?(s.dex>s.str?'dex':'str'):(ranged?'dex':'str')):s.ability;
    const abilityMod=mod(s[ability]);
    const attack=s.direct?s.attackTotal:abilityMod+s.proficiency+s.magic+s.attackOther;
    const damage=s.direct?s.damageTotal:(w.fixed_damage!==null?0:abilityMod)+s.magic+s.damageOther;
    const custom=['manual','natural'].includes(a.id),base=custom?s.customBase:a.base;
    const cap=custom?({none:0,full:null,cap2:2}[s.customDex]):a.dexCap;
    const dexApplied=cap===0?0:Math.min(mod(s.defDex),cap??Infinity);
    const extra=dexApplied+s.armorMagic+(s.shield?2+s.shieldMagic:0)+s.defenseOther+s.cover;
    const pool=parseDice(w['dice_'+s.hands] || String(w.fixed_damage));
    return {w,a,ability,abilityMod,attack,damage,base,dexApplied,ac:base+extra,defense:extra,pool,profile:custom?s.profile:a.profile};
  }
  function lookup(family,armor,natural,total,attack,bonusDefense,criticalAt=20) {
    const points=DATA.families[family][armor],rawIndex=5*(total+attack-bonusDefense),index=Math.max(0,Math.floor(rawIndex));
    let quality=0,tableHit=false;
    for(const [min,q] of points)if(index>=min){quality=q;tableHit=true;}
    const crit=natural>=criticalAt,hit=natural!==1 && (crit || tableHit);
    return {index,rawIndex,hit,crit:hit && crit,quality:hit?(crit?1:quality):0,overflow:hit?Math.max(0,(index-points.at(-1)[0])/5):0,tailStart:points.at(-1)[0]};
  }
  function prepare(s) {
    const d=derive(s),native=new Map();
    // Cache the two native critical/noncritical typed pools; only the base changes.
    for(const crit of [false,true]) {
      const extra=new Map();
      for(const part of s.extras){const p=parseDice(part.dice),faces=crit && part.crit?p.faces.concat(p.faces):p.faces;const pmf=dicePMF(faces,p.flat);extra.set(part.type,convolve(extra.get(part.type)||point(0),pmf));}
      const faces=crit?d.pool.faces.concat(d.pool.faces):d.pool.faces;
      native.set(crit,{extra,base:dicePMF(faces,d.pool.flat+d.damage)});
    }
    const meanDice=d.pool.faces.reduce((n,sides)=>n+(sides+1)/2,0);
    function distribution(crit,physical=null,overflow=0) {
      const pools=native.get(crit),byType=new Map(pools.extra);
      let base=physical===null?pools.base:point(physical+d.pool.flat+d.damage);
      if(overflow)base=transform(base,n=>n+overflow);
      byType.set(d.w.damage_type,convolve(byType.get(d.w.damage_type)||point(0),base));
      let pmf=point(0);const components=[];
      for(const [type,p] of byType){const applied=transform(p,n=>defense(n,type,s));components.push({type,raw:stats(p),applied:stats(applied)});pmf=convolve(pmf,applied);}
      return {...stats(pmf),pmf,components};
    }
    const nativeHit=distribution(false),nativeCrit=distribution(!s.cancelCritical);
    function bridge(r,total=r) {
      const l=lookup(d.w.group,d.profile,r,total,d.attack,d.defense,s.criticalAt);
      if(!l.hit)return {...stats(point(0)),pmf:point(0),components:[],lookup:l,hit:false,crit:false,supplement:0};
      const crit=l.crit && !s.cancelCritical;
      // A prevented critical is still a critical attack for table quality: neutral
      // native damage is the explicit armor option, not an extra percentile bonus.
      const supplemental=Math.floor(meanDice*l.overflow/10);
      const physical=l.crit || !d.pool.faces.length?null:quantile(d.pool.faces,l.quality);
      return {...distribution(crit,physical,supplemental),lookup:l,hit:true,crit,supplement:supplemental};
    }
    return {d,meanDice,distribution,nativeHit,nativeCrit,bridge};
  }
  function openDistribution(s,ctx) {
    const {d,meanDice,bridge}=ctx,type=d.w.damage_type;
    if(!meanDice || s.immune.includes(type)) {
      const out=bridge(20,21);return {...out,tailProbability:0,unbounded:false};
    }
    // k is the count of ADDITIONAL twenties before final j=1..19.
    // Each branch has probability 20^-(k+1), conditional on initial 20.
    // Choose K large enough that the tail is affine, even after negative flats.
    const points=DATA.families[d.w.group][d.profile],threshold=points.at(-1)[0]/5-d.attack+d.defense;
    const flatDebt=Math.abs(d.damage)+Math.abs(d.pool.flat)+s.extras.reduce((n,x)=>n+Math.abs(parseDice(x.dice).flat),0);
    const K=Math.max(10,Math.ceil((threshold-21+10*flatDebt/meanDice)/20)+2);
    const pmf=new Map();let mean=0,min=Infinity;
    for(let k=0;k<K;k++)for(let j=1;j<=19;j++) {
      const w=Math.pow(20,-k-1),out=bridge(20,20*(k+1)+j);
      mean+=w*out.mean; min=Math.min(min,out.min);
      for(const [n,p]of out.pmf)add(pmf,n,w*p);
    }
    // Two more twenties add 4*meanDice (an EVEN integer) before defenses.
    // Consequently resistance floor has the same parity and the tail translates.
    let shift=4*meanDice;if(s.resist.includes(type))shift/=2;if(s.vulnerable.includes(type))shift*=2;
    const ratio=1/400;
    for(let b=0;b<2;b++)for(let j=1;j<=19;j++) {
      const out=bridge(20,20*(K+b+1)+j),w=Math.pow(20,-K-b-1);
      mean+=w*(out.mean/(1-ratio)+shift*ratio/(1-ratio)**2);
    }
    return {pmf,min,max:Infinity,mean,mass:1,hit:true,crit:!s.cancelCritical,unbounded:true,tailProbability:Math.pow(20,-K),components:[]};
  }
  function analyze(input) {
    const s=validate(input),ctx=prepare(s),rows=[];
    const sums={old:{pmf:new Map(),mean:0,hit:0,crit:0,min:Infinity,max:0,tailProbability:0},bridge:{pmf:new Map(),mean:0,hit:0,crit:0,min:Infinity,max:0,tailProbability:0}};
    for(let r=1;r<=20;r++) {
      const p=weight(r,s.mode),nativeCritical=r>=s.criticalAt,hit=r!==1 && (nativeCritical || r+ctx.d.attack>=ctx.d.ac);
      const old=hit?{...(nativeCritical?ctx.nativeCrit:ctx.nativeHit),hit:true,crit:nativeCritical && !s.cancelCritical}:{...stats(point(0)),pmf:point(0),hit:false,crit:false,components:[]};
      const bridge=r===20 && s.open?openDistribution(s,ctx):ctx.bridge(r);
      rows.push({r,p,old,bridge});
      for(const [key,out]of [['old',old],['bridge',bridge]]) {
        const sum=sums[key];sum.mean+=p*out.mean;sum.hit+=p*Number(out.hit);sum.crit+=p*Number(out.crit);sum.min=Math.min(sum.min,out.min);sum.max=Math.max(sum.max,out.max);sum.tailProbability+=p*(out.tailProbability||0);
        for(const [n,q]of out.pmf)add(sum.pmf,n,p*q);
      }
    }
    for(const sum of Object.values(sums)){sum.mass=1;sum.onHit=sum.hit?sum.mean/sum.hit:0;}
    return {s,d:ctx.d,rows,sums};
  }
  function chain(input,twenties,final) {
    const s=validate(input);number(twenties,1,10000,'Veintes consecutivos');number(final,1,19,'Último dado');
    return prepare(s).bridge(20,20*twenties+final);
  }
  function percentile(pmf,q) {let acc=0,last=0;for(const [n,p]of [...pmf].sort((a,b)=>a[0]-b[0])){acc+=p;last=n;if(acc>=q)return n;}return last;}
  function encode(s) {return '#s='+encodeURIComponent(JSON.stringify(validate(s)));}
  function decode(hash) {if(!hash.startsWith('#s=') || hash.length>12000)throw new Error('Enlace de escenario no válido.');return validate(JSON.parse(decodeURIComponent(hash.slice(3))));}
  return {DATA,TYPES,GROUPS,ARMORS,defaults,clone,mod,validate,parseDice,quantile,dicePMF,convolve,transform,stats,weight,defense,derive,lookup,analyze,chain,percentile,encode,decode};
});
