'use strict';
import * as http from './lib/http.uc';
let u=require('uloop');u.init();
let base='http://127.0.0.1:'+ARGV[0],count=0,stream='';
function check(ok,msg){if(!ok)die(msg);}
function completed(){if(++count==2){print('Native loopback success stream and error body OK\n');u.end();}}
http.request({url:base+'/ok',timeout_ms:3000,on_data:(chunk)=>{stream+=chunk;},on_done:(status,h,body)=>{check(status==200 && stream=='fixture-data','native streaming');completed();},on_error:(err)=>die(err)});
http.request({url:base+'/error',timeout_ms:3000,on_data:()=>die('error must not stream'),on_done:(status,h,body)=>{check(status==400 && body=='Unknown SID','native error body');completed();},on_error:(err)=>die(err)});
u.timer(5000,()=>die('loopback timeout'));
u.run();
