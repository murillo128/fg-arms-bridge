#!/usr/bin/env python3
"""Check browser data, Node contracts and parity with the actual shipped Lua engine.
Requires Node >=18 and the same Lua executable/shared library as tools/test.py.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from test import find_lua, run_lua

LUA = r'''
local E = dofile('extension/scripts/arms_engine.lua')
local pools = {{4},{6},{8},{10},{12},{6,6}}
for _,family in ipairs(E.getDefaultTableIds()) do
 for armor,_ in pairs(E.getTable(family).armors) do
  for _,bonus in ipairs({-5,0,5,13,25}) do
   for _,defense in ipairs({-2,0,5,12}) do
    for natural=1,20 do
     local chains = natural == 20 and {{20,1},{20,10},{20,20,19},{20,20,20,10}} or {{natural}}
     for _,chain in ipairs(chains) do
      local r = assert(E.resolve({weapon=family,armor=armor,natural=natural,open_roll=chain,attack_bonus=bonus,defense=defense}))
      local values={family,armor,natural,r.roll_total,bonus,defense,r.hit and 1 or 0,r.critical and 1 or 0,r.quality,r.overflow,r.index}
      for _,pool in ipairs(pools) do
       local faces=assert(E.damageDice(pool,r.quality));local sum=0;for _,face in ipairs(faces)do sum=sum+face end
       values[#values+1]=sum;values[#values+1]=assert(E.damageOverflow(pool,r.overflow))
      end
      print(table.concat(values,'\t'))
     end
    end
   end
  end
 end
end
'''
NODE = r'''
const fs=require('node:fs'), assert=require('node:assert/strict');
const A=require(process.cwd()+'/docs/simulator/engine.js');
let rows=0;
for(const line of fs.readFileSync(process.argv[1],'utf8').trim().split('\n')){
 const v=line.split('\t'),family=v[0],armor=v[1],n=v.slice(2).map(Number);
 const r=A.lookup(family,armor,n[0],n[1],n[2],n[3]);
 assert.deepEqual([Number(r.hit),Number(r.crit),r.quality,r.overflow,r.index],n.slice(4,9),line);
 [[4],[6],[8],[10],[12],[6,6]].forEach((pool,i)=>{
  assert.equal(A.quantile(pool,r.quality),n[9+i*2],line);
  assert.equal(Math.floor(pool.reduce((s,d)=>s+(d+1)/2,0)*r.overflow/10),n[10+i*2],line);
 });rows++;
}
console.log('PASS '+rows+' browser/Lua attack cases; six dice pools and supplements per case.');
'''


def main():
    subprocess.run([sys.executable, 'tools/export_simulator.py', '--check'], cwd=ROOT, check=True)
    subprocess.run(['node', '--test', 'tests/simulator.test.cjs'], cwd=ROOT, check=True)
    backend = find_lua()
    if not backend:
        raise SystemExit('Lua is required for parity; install Lua 5.4. No check was skipped.')
    with tempfile.TemporaryDirectory(prefix='arms-web-parity-') as temp:
        source=Path(temp)/'oracle.lua'; source.write_text(LUA)
        ok,output=run_lua(backend,'test',source,ROOT,60)
        if not ok:
            raise SystemExit(output)
        fixture=Path(temp)/'oracle.tsv';fixture.write_text(output)
        subprocess.run(['node','-e',NODE,str(fixture)],cwd=ROOT,check=True)


if __name__ == '__main__':
    main()
