'use strict';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
let client=SponsorBlockClient({apikey:'',devices:[]}),fixtures=[['jNQXAC9IVRw','UC4QobU6STFB0P71PMvOGN5A'],['dQw4w9WgXcQ','UCuAXFkgsw1L7xaCfnd5JJOw'],['M7lc1UVf-VE','UC_x5XG1OV2P6uZZ5FSM9Ttw']],failures=0;
function next(){
    if(!length(fixtures)){print('Network channel lookup failures: '+failures+'\n');u.end();return;}
    let pair=shift(fixtures),start=util.monotonic_ms();
    client.get_channel_id(pair[0],(channel)=>{
        let ok=channel==pair[1];if(!ok)failures++;
        print(pair[0]+' '+(ok?'PASS':'FAIL')+' '+channel+' '+(util.monotonic_ms()-start)+' ms\n');
        next();
    },(err)=>{failures++;print(pair[0]+' FAIL '+err+'\n');next();});
}
next();u.run();
if(failures)exit(1);
