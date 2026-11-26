'use strict';
import {availability_status as status} from './lib/util.uc';
function check(ok,msg){if(!ok)die(msg);}
let id='fixture123',token='fixture-token';
check(status({screens:[{status:'online'}]},id,token)===true,'single-token anonymous response');
check(status({screens:[{loungeToken:token,status:'online'}]},id,token)===true,'token-only response');
check(status({screens:[{screenId:id,status:'online'}]},id,token)===true,'screen ID response');
check(status({screens:[{status:'offline'}]},id,token)===false,'offline remains offline');
check(status({},id,token)===false,'empty response means no available screen');
check(status({screens:[]},id,token)===false,'empty screens means no available screen');
check(status({unexpected:true},id,token)==null,'malformed response stays unknown');
check(status({screens:null},id,token)==null,'null list stays unknown');
check(status({screens:[{screenId:'wrong',status:'online'}]},id,token)==null,'reject wrong ID');
check(status({screens:[{screenId:id,loungeToken:'wrong',status:'online'}]},id,token)==null,'reject wrong token');
check(status({screens:[{status:'online'},{status:'offline'}]},id,token)==null,'reject ambiguous result');
check(status({screens:[{status:'online'}]},id,'one,two')==null,'reject multiple tokens');
check(status({screens:[{status:'unknown'}]},id,token)==null,'reject unknown status');
print('Single-token availability compatibility and mismatch rejection OK\n');
