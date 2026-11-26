'use strict';
import * as fs from 'fs';
import * as util from './lib/util.uc';
const DEFAULT_DATA_DIR='/etc/sponsorblocktv/data';
function parse_args(argv) {
    let args={data_dir:getenv('SBTV_DATA_DIR')||DEFAULT_DATA_DIR,debug:false,http_tracing:false,check_only:false};
    let seen={};
    for(let i=0;i<length(argv);i++){
        let flag=argv[i]=='-d'?'--data':argv[i];
        if(seen[flag] || index(['--data','--debug','--check','--http-tracing'],flag)<0)return null;
        seen[flag]=true;
        if(flag=='--data'){
            let value=argv[++i];
            if(type(value)!='string' || !length(value) || substr(value,0,1)=='-')return null;
            args.data_dir=value;
        }else if(flag=='--debug')args.debug=true;
        else if(flag=='--http-tracing')args.http_tracing=true;
        else args.check_only=true;
    }
    return args;
}

function load_config(data_dir) {
	let path = data_dir + '/config.json';
	let st=fs.lstat(path);
    if(!st || st.type!='file' || st.size>1048576 || st.size<2){
        util.error('run','Missing, invalid or oversized config.json');
        return null;
    }
    let text=fs.readfile(path);
    if(type(text)!='string' || length(text)>1048576){
        util.error('run','Unable to read configuration');
        return null;
    }
	let data;
	try {
		data = json(text);
	}
	catch (e) {
		util.error('run', 'config.json is not valid JSON');
		return null;
	}
	if (type(data) != 'object') {
		util.error('run', path + ' must contain a JSON object');
		return null;
	}
	return data;
}


function check(ok,msg){if(!ok)die(msg);}
check(parse_args(['--check','-d','/mnt/test']).check_only,'valid arguments');
for(let bad in [['--data'],['--data','--check'],['--debug','--debug'],['-d','/mnt/a','--data','/mnt/b'],['--unknown']])check(!parse_args(bad),'invalid arguments rejected');
check(load_config('/proc')==null,'missing config rejected');
print('Launcher argument validation and missing file handling OK\n');
