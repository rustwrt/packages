'use strict';
import {plan_device,unique_device_name} from './lib/pair_store.uc';
import {build_config,parse_uci_show} from './lib/config.uc';
function check(ok,msg){if(!ok)die(msg);}
function rejects(fn){try{fn();return false;}catch(e){return true;}}
let ds=[{name:'@device[0]',type:'device',options:{screen_id:'fixture123'}},{name:'@device[1]',type:'device',options:{screen_id:''}}];
check(plan_device(ds,'','fixture123','TV').unchanged,'repeat pairing idempotent');
check(rejects(()=>plan_device(ds,'@device[1]','fixture123','TV')),'duplicate target rejected');
check(!plan_device(ds,'@device[1]','fixture234','TV').unchanged,'existing blank slot accepted');
check(plan_device([{name:'cfg123',type:'device',options:{}}],'@device[0]','fixture234','TV').section=='cfg123','anonymous index resolves named UCI section');
check(rejects(()=>plan_device(ds,'main','fixture234','TV')),'non-device rejected');
check(rejects(()=>plan_device(ds,'','fixture234',{})),'invalid name type');
for(let i=2;i<65;i++)push(ds,{name:'dev'+i,type:'device',options:{screen_id:'fixture'+(1000+i)}});
check(rejects(()=>plan_device(ds,'','fixture999','TV')),'device cap before adding');
check(rejects(()=>plan_device(ds,'@device[1]','fixture999','TV')),'device cap before filling');
check(!plan_device(ds,'@device[0]','fixture999','TV').unchanged,'replacement permitted at cap');
let c=build_config(parse_uci_show("sponsorblocktv.main=sponsorblocktv\nsponsorblocktv.@device[0]=device\nsponsorblocktv.@device[0].screen_id='fixture123'\nsponsorblocktv.@device[0].offset=''\n"));
check(c.devices[0].offset==0,'empty offset defaults to zero');
print('Pairing duplicate prevention, device limit, input validation and empty offset OK\n');

let names=[{name:'a',type:'device',options:{screen_id:'fixture001',name:'Samsung TV'}},{name:'b',type:'device',options:{screen_id:'fixture002',name:'Samsung TV #2'}}];
check(unique_device_name(names,'Samsung TV','')=='Samsung TV #3','duplicate gets first free suffix');
check(unique_device_name(names,'Other TV','')=='Other TV','unique name unchanged');
check(unique_device_name(names,'Samsung TV','a')=='Samsung TV','exclude current section');
print('Duplicate display names receive numbered suffixes\n');
