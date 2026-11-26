'use strict';
import {request_with_client} from './lib/http.uc';
let u=require('uloop');u.init();
let calls=[],h;
let f={set_timeout:()=>{},connect:()=>true,request:()=>true,disconnect:()=>push(calls,'disconnect'),free:()=>push(calls,'free')};
h=request_with_client({url:'http://fixture/',timeout_ms:0,on_done:()=>die('cancel notified'),on_error:()=>die('cancel notified')},()=>f);
h.free();h.free();
u.timer(50,()=>{
 if(join(',',calls)!='disconnect,free')die('native disconnect before exactly one free');
 print('Native cancellation ordering OK\n');u.end();
});
u.run();
