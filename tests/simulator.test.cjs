'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const A=require('../docs/simulator/engine.js');
const make=patch=>({...A.clone(A.defaults),...patch});
const near=(a,b,e=1e-10)=>assert.ok(Math.abs(a-b)<e,`${a} != ${b}`);

test('mockup regression: actual independent 1d8+4 plus resisted 1d4',()=>{
 const a=A.analyze(A.defaults),old=a.rows[14].old,bridge=a.rows[14].bridge;
 assert.deepEqual([old.min,old.mean,old.max],[5,9.5,14]);
 assert.deepEqual([bridge.min,bridge.mean,bridge.max],[8,9,10]);
 near(a.sums.old.mean,5.5125);near(a.sums.old.hit,.55);near(a.sums.bridge.hit,.4);
 // Conditional 20: native mean 15.25 plus (68 + 9)/19 from the floor sum
 // of the 19 endings and the geometric expected number of extra twenties.
 near(a.rows[19].bridge.mean,15.25+77/19);near(a.sums.bridge.mean,4.315131578947368);
 assert.equal(a.rows[19].bridge.max,Infinity);
});
test('each initial d20 weight, including advantage and disadvantage',()=>{
 for(const mode of ['normal','advantage','disadvantage'])near(Array.from({length:20},(_,i)=>A.weight(i+1,mode)).reduce((a,b)=>a+b),1);
 near(A.weight(20,'advantage'),.0975);near(A.weight(20,'disadvantage'),.0025);
 const a=A.analyze(make({mode:'advantage'}));near(a.sums.old.hit,1-.45**2);near(a.sums.old.crit,.0975);
});
test('minimum natural die misses even with absurd positive attack; 20 hits with negative attack',()=>{
 const a=A.analyze(make({direct:true,attackTotal:50}));assert.equal(a.rows[0].old.max,0);assert.equal(a.rows[0].bridge.max,0);
 const b=A.analyze(make({direct:true,attackTotal:-30}));assert.ok(b.rows[19].old.hit && b.rows[19].bridge.hit);
});
test('exact quantiles: 1d12 median=6, 2d6 quartile=5',()=>{
 assert.equal(A.quantile([12],.5),6);assert.equal(A.quantile([6,6],.25),5);assert.equal(A.quantile([8],.45),4);
 assert.equal(A.quantile([6,6],.5),7);assert.equal(A.quantile([6,6],.9),10);
});
test('typed damage applies floor to outcomes, not to their mean',()=>{
 const p=A.transform(A.dicePMF([4]),d=>A.defense(d,'fire',make({resist:['fire']})));
 near(A.stats(p).mean,1);assert.notEqual(A.stats(p).mean,2.5/2);
 assert.deepEqual([...p].sort((a,b)=>a[0]-b[0]),[[0,.25],[1,.5],[2,.25]]);
});
test('same damage type combines BEFORE resistance: two d4s have mean 2.25, not 2',()=>{
 const a=A.analyze(make({extras:[{dice:'1d4',type:'fire',crit:true},{dice:'1d4',type:'fire',crit:true}]}));
 near(a.rows[14].bridge.mean,10.25);near(a.rows[14].old.mean,10.75);
});
test('immunity precedes resistance; resistance precedes vulnerability',()=>{
 assert.equal(A.defense(3,'fire',make({resist:['fire'],vulnerable:['fire']})),2);
 assert.equal(A.defense(3,'fire',make({immune:['fire'],resist:['fire'],vulnerable:['fire']})),0);
});
test('base immunity removes physical damage, NOT the rider or hit',()=>{
 const a=A.analyze(make({immune:['slashing']}));const r=a.rows[14];
 assert.deepEqual([r.bridge.min,r.bridge.mean,r.bridge.max],[0,1,2]);assert.equal(r.bridge.hit,true);
 assert.equal(a.rows[19].bridge.max,4);near(a.rows[19].bridge.mean,2.25);
});
test('a critical doubles dice, not constants; extra component can be ineligible',()=>{
 const a=A.analyze(make({open:false,magic:0,extras:[{dice:'1d4+3',type:'fire',crit:false}],resist:[]}));
 // 2d8+3 plus 1d4+3.
 assert.deepEqual([a.rows[19].old.min,a.rows[19].old.mean,a.rows[19].old.max],[9,17.5,26]);
});
test('cancelled critical uses native single dice without a percentile bonus',()=>{
 const a=A.analyze(make({open:false,cancelCritical:true}));
 near(a.rows[19].old.mean,9.5);near(a.rows[19].bridge.mean,9.5);assert.equal(a.sums.old.crit,0);
});
test('expanded native critical range does not make 19 open',()=>{
 const a=A.analyze(make({criticalAt:19}));assert.equal(a.rows[18].bridge.max,24);assert.equal(a.rows[19].bridge.max,Infinity);
 near(a.sums.old.crit,.1);
});
test('light, medium and heavy armor treat negative and high Dex differently',()=>{
 near(A.derive(A.validate(make({armor:'plate',defDex:6}))).dexApplied,0);
 near(A.derive(A.validate(make({armor:'halfplate',defDex:6}))).dexApplied,-2);
 near(A.derive(A.validate(make({armor:'halfplate',defDex:20}))).dexApplied,2);
 near(A.derive(A.validate(make({armor:'leather',defDex:20}))).dexApplied,5);
});
test('shield magic is applied only when a shield exists; no double-count of material AC',()=>{
 const a=A.derive(A.validate(make({armor:'plate',armorMagic:1,shield:2,shieldMagic:2,defenseOther:1})));
 assert.deepEqual([a.ac,a.base,a.defense],[24,18,6]);
 assert.equal(A.derive(A.validate(make({shield:0,shieldMagic:3}))).ac,17);
});
test('material CA limitation is preserved and exposed, not silently repaired',()=>{
 const a=A.analyze(make({armor:'plate'})),b=A.analyze(make({armor:'splint'}));
 assert.notEqual(a.sums.old.mean,b.sums.old.mean);near(a.sums.bridge.mean,b.sums.bridge.mean);
});
test('natural armor takes explicit material and Dexterity settings without granting resistances',()=>{
 const s=make({armor:'natural',customBase:16,customDex:'full',profile:'natural_scales',defDex:14,resist:[]});
 const a=A.analyze(s);assert.deepEqual([a.d.ac,a.d.base,a.d.defense,a.d.profile],[18,16,2,'natural_scales']);assert.deepEqual(a.s.resist,[]);
});
test('versatile grip changes dice, not attack bonus or damage multipliers',()=>{
 const a=A.analyze(make({hands:'2h'}));near(a.d.attack,7);near(a.d.damage,4);assert.deepEqual(a.d.pool.faces,[10]);
 assert.throws(()=>A.validate(make({weapon:'greataxe',hands:'1h'})));
});
test('ranged and finesse automatic ability; explicit attack totals are totals',()=>{
 assert.equal(A.derive(A.validate(make({weapon:'longbow',hands:'2h'}))).ability,'dex');
 assert.equal(A.derive(A.validate(make({weapon:'rapier',str:10,dex:18}))).ability,'dex');
 const a=A.derive(A.validate(make({direct:true,attackTotal:9,damageTotal:12,magic:3})));assert.deepEqual([a.attack,a.damage],[9,12]);
});
test('blowgun preserves fixed native damage and cannot acquire an infinite tail',()=>{
 const a=A.analyze(make({weapon:'blowgun',hands:'1h',magic:0,extras:[],resist:[]}));
 assert.equal(a.rows[19].old.max,1);assert.equal(a.rows[19].bridge.max,1);assert.equal(a.d.damage,0);
});
test('20+1 is not a fumble; later twenties add exactly 2*meanDice to the supplement',()=>{
 const s=make({direct:true,attackTotal:5,damageTotal:3,armor:'plate',armorMagic:0,shield:0,defenseOther:0});
 assert.equal(A.chain(s,1,1).hit,true);assert.equal(A.chain(s,1,1).supplement,0);assert.equal(A.chain(s,1,10).supplement,4);
 assert.equal(A.chain(s,2,10).supplement,13);assert.equal(A.chain(s,100,10).supplement,4+99*9);
 assert.throws(()=>A.chain(s,1,20));
});
test('analytic tail preserves probability, finite expectation and unbounded max across resistance parity',()=>{
 for(const settings of [{},{resist:['piercing','fire']},{resist:['piercing'],vulnerable:['piercing']},{damageOther:-80,extras:[]}]) {
  const a=A.analyze(make({weapon:'dagger',...settings}));
  for(const sum of Object.values(a.sums))near(A.stats(sum.pmf).mass+sum.tailProbability,1);
  assert.ok(Number.isFinite(a.sums.bridge.mean));assert.equal(a.sums.bridge.max,Infinity);
 }
});
test('all 40 weapons and all armor profiles produce normalized distributions',()=>{
 for(const w of A.DATA.weapons){const a=A.analyze(make({weapon:w.id,hands:w.dice_1h || w.fixed_damage!==null?'1h':'2h'}));for(const sum of Object.values(a.sums))near(A.stats(sum.pmf).mass+sum.tailProbability,1);}
 for(const p of A.DATA.profiles){const a=A.analyze(make({armor:'natural',profile:p.id}));assert.ok(Number.isFinite(a.sums.bridge.mean));}
});
test('negative total damage clamps to zero and never heals the target',()=>{
 const a=A.analyze(make({direct:true,attackTotal:7,damageTotal:-100,extras:[],open:false}));
 for(const r of a.rows){assert.equal(r.old.min,0);assert.equal(r.bridge.min,0);}
});
test('validated URL scenario roundtrip including accents-safe encoding',()=>{
 const s=A.validate(make({weapon:'trident',extras:[{dice:'2d6+1d4-2',type:'necrotic',crit:true}],immune:['acid']}));
 assert.deepEqual(A.decode(A.encode(s)),s);
 assert.throws(()=>A.decode('#s=%'));assert.throws(()=>A.decode('#s='+encodeURIComponent('{"weapon":"<script>"}')));
});
test('grammar and computational limits reject malicious or unbounded inputs',()=>{
 for(const x of ['alert(1)','2d6*10','1d4;globalThis.pwn=true','-1d6','200d6','1d1','1d999','Infinity',''])assert.throws(()=>A.parseDice(x));
 assert.throws(()=>A.validate(make({attackOther:Infinity})));assert.throws(()=>A.validate(make({extras:Array(7).fill({dice:'1d4',type:'fire',crit:true})})));
 assert.throws(()=>A.validate(make({immune:['not-a-type']})));
 assert.equal(globalThis.pwn,undefined);
});

test('resisted open d4: analytic expectation agrees with independent exhaustive critical dice and geometric branches',()=>{
 const s=make({weapon:'dagger',hands:'1h',direct:true,attackTotal:5,damageTotal:3,armor:'plate',extras:[],resist:['piercing']});
 const a=A.analyze(s);let expected=0;
 for(let k=0;k<25;k++)for(let j=1;j<=19;j++)for(let x=1;x<=4;x++)for(let y=1;y<=4;y++)
  expected+=Math.floor((x+y+3+5*k+Math.floor((j-1)/4))/2)/(16*20**(k+1));
 near(a.rows[19].bridge.mean,expected);
});
