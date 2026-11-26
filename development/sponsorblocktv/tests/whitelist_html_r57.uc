'use strict';
import {watch_channel_id} from './lib/sponsorblock.uc';
import * as fs from 'fs';
let fixtures=[['jNQXAC9IVRw','UC4QobU6STFB0P71PMvOGN5A'],['dQw4w9WgXcQ','UCuAXFkgsw1L7xaCfnd5JJOw'],['M7lc1UVf-VE','UC_x5XG1OV2P6uZZ5FSM9Ttw']];
for(let pair in fixtures){
 let ch=watch_channel_id(fs.readfile(ARGV[0]+'/'+pair[0]+'.html'),pair[0]);
 if(ch!=pair[1])die('Public HTML fixture mismatch: '+pair[0]);
 print(pair[0]+' PASS '+ch+'\n');
}
