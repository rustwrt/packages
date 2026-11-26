'use strict';
import * as fs from 'fs';
import {controller_seed,persistent_controller_id,YtLoungeApi} from './lib/lounge.uc';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
function check(ok,msg){if(!ok)die(msg);}
let dir=ARGV[0],other=ARGV[1],seed=controller_seed(dir);
let id=persistent_controller_id(seed,'abcdefghijk');
let cfg={devices:[],skip_categories:[]},helper=SponsorBlockClient(cfg);
let screen={type:'LOUNGE_SCREEN',id:'screen'},phone={type:'REMOTE_CONTROL',id:'phone',name:'Phone'};
for(let i=0;i<100;i++){
    let current=controller_seed(dir);
    let listener=DeviceListener(helper,cfg,{screen_id:'abcdefghijk',name:'TV'},false,persistent_controller_id(current,'abcdefghijk'));
    let a=listener.lounge;
    check(a.device_id===id,'restart changed controller identity');
    a._sid='s'+i;a._gsession='g'+i;
    a._process_event('loungeStatus',[{devices:[screen,phone,{type:'REMOTE_CONTROL',id:id},{type:'REMOTE_CONTROL',id:a.device_id}]}]);
    check(length(a.controllers)==2 && a.controllers[1].self,'roster must deduplicate identical ID and retain phone');
    a.detach();check(!a.connected(),'local detach');
}
check(persistent_controller_id(seed,'lmnopqrstuv')!==id,'different TV');
check(persistent_controller_id(controller_seed(other),'abcdefghijk')!==id,'different installation');
check(YtLoungeApi({screen_id:'abcdefghijk'}).device_id!==id,'independent client');
let file=dir+'/controller-id';
check(!(fs.lstat(file).mode & 63),'private identity file');
fs.chmod(file,0644);
let rejected=false;try{controller_seed(dir);}catch(e){rejected=true;}
check(rejected,'unsafe seed must not silently rotate');
fs.chmod(file,0600);
check(controller_seed(dir)===seed,'identity retained');
print('PASS: 100 simulated restarts, separate TV/router identities, private seed and accurate roster\n');
