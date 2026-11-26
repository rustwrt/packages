'use strict';
import {request_with_client} from './lib/http.uc';
import {YtLoungeApi} from './lib/lounge.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let clients=[];
function factory(url,proxy,cb){
    let f={...cb,chunks:[],freed:0,status:()=>({status:200}),
        read:function(){return shift(this.chunks);},get_headers:()=>({}),ssl_init:()=>true,
        set_timeout:()=>{},connect:()=>true,request:()=>true,free:function(){this.freed++;}};
    push(clients,f);return f;
}
let errors=0,done=0,cancelled=0,streamed=0;
request_with_client({url:'http://fixture/',timeout_ms:30,on_data:()=>streamed++,on_error:(e)=>{check(e=='request deadline exceeded','absolute deadline');errors++;}},factory);
let h=request_with_client({url:'http://fixture/',on_done:()=>cancelled++,on_error:()=>cancelled++},factory);
clients[1].data_eof();h.free();
let long=request_with_client({url:'http://fixture/',timeout_ms:0,on_done:()=>done++,on_error:()=>errors++},factory);
clients[0].chunks=['slow'];clients[0].data_read();
let a=YtLoungeApi({screen_id:'fixture',lounge_token:'fixture'});
a._sid='s';a._gsession='g';a._subscribe_buffer='part';a._current_chunk='old';a._chunk_remaining=20;
a._connection_lost();
check(a._subscribe_buffer=='' && a._current_chunk=='' && a._chunk_remaining==-1,'disconnect releases partial frames');
u.timer(100,()=>{
    check(errors==1 && cancelled==0 && streamed==1,'deadline and queued cancel semantics');
    check(clients[0].freed==1 && clients[1].freed==1 && clients[2].freed==0,'dispose once; unlimited stream remains');
    clients[0].data_eof();long.free();
    u.timer(20,()=>{check(done==0 && clients[2].freed==1,'stream cancels safely');print('Absolute HTTP deadline, deferred callback cancellation and frame reset OK\n');u.end();});
});
u.run();
