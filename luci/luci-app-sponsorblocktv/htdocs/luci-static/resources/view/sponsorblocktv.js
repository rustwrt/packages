'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require rpc';
'require poll';

// This catalog is private to this view. Never modify LuCI's global translator.
var appLanguage='en', vietnameseCatalog=null;
function tr(message){
    return appLanguage==='vi' && vietnameseCatalog && Object.prototype.hasOwnProperty.call(vietnameseCatalog,message) && typeof vietnameseCatalog[message]==='string'
        ? vietnameseCatalog[message] : message;
}
async function loadAppLanguage(){
    // LuCI resolves its System > Language setting (including Auto) server-side.
    // Read the effective document language, not the browser's preferences.
    var language=String(document.documentElement?.lang||'en').toLowerCase().replace(/_/g,'-');
    vietnameseCatalog=null;appLanguage='en';
    try{
        if(/^vi(?:-|$)/.test(language) && typeof window.fetch==='function'){
            var response=await window.fetch(L.resource('sponsorblocktv/i18n/vi.json')+'?v=128',{cache:'no-store',credentials:'same-origin'});
            if(response.ok){
                var data=await response.json();
                if(data && typeof data==='object' && !Array.isArray(data) && typeof data['Volume']==='string'){
                    vietnameseCatalog=data;appLanguage='vi';
                }
            }
        }
    }catch(e){}
    CATEGORIES=categoryLabels.map(function(c){return [c[0],tr(c[1])];});
}
var getLiveStatus = rpc.declare({ object: 'sponsorblocktv.live', method: 'status', reject: true, expect: { '': {} } });
var sendLiveCommand = rpc.declare({ object: 'sponsorblocktv.live', method: 'control', reject: true, params: ['id', 'action', 'value', 'text'], expect: { '': {} } });
var saveLivePolicy = rpc.declare({object:'sponsorblocktv.live',method:'policy',reject:true,params:['id','key','value'],expect:{'':{}}});

function clearFeedback(node) {
    if (!node) return;
    window.clearTimeout(node._feedbackTimer);
    node._feedbackTimer=null;
    node._feedbackRevision=(node._feedbackRevision||0)+1;
    if(node._feedbackAnimation){node._feedbackAnimation.cancel();node._feedbackAnimation=null;}
    node.style.display='none';
    node.replaceChildren();
    node.setAttribute('aria-busy','false');
}
function actionFeedback(node, message, kind, persistent) {
    if (!node) return;
    clearFeedback(node);
    node.style.display = 'block';
    node.style.color = kind === 'error' ? '#b42318' : kind === 'success' ? '#25803b' : '';
    node.setAttribute('aria-busy', kind === 'busy' ? 'true' : 'false');
    node.replaceChildren(kind === 'busy' ? E('span', { 'aria-hidden': 'true', 'class': 'sbtv-action-spinner' }) : E('span', { 'aria-hidden': 'true' }, [kind === 'success' ? '\u2713 ' : kind === 'error' ? '\u26a0 ' : '']), E('span', {}, [message]));
    if(kind==='success' && !persistent){
        var revision=node._feedbackRevision;
        node._feedbackTimer=window.setTimeout(function(){
            if(node._feedbackRevision!==revision)return;
            node._feedbackTimer=null;
            if(!node.isConnected){clearFeedback(node);return;}
            function finish(){if(node._feedbackRevision===revision)clearFeedback(node);}
            if(!motionAllowed(node)){finish();return;}
            try{
                var anim=node.animate([{opacity:1},{opacity:0}],{duration:200,easing:'ease-out',fill:'forwards'});
                node._feedbackAnimation=anim;
                anim.onfinish=finish;
                if(anim.finished)anim.finished.then(finish,function(){});
            }catch(e){finish();}
        },3000);
    }
}
function buttonBusy(button, busy, label) {
    if (!button) return;
    button.disabled = busy;
    button.setAttribute('aria-busy', busy ? 'true' : 'false');
    button.style.cursor = busy ? 'wait' : '';
    if (label != null) button.textContent = label;
}
// Lucide static SVG assets are packaged locally; CSS masking inherits theme color.
function liveIcon(name, detail) {
    var url = L.resource('sponsorblocktv/icons/'+name+'.svg');
    var glyph = E('span',{'class':'sbtv-live-icon','aria-hidden':'true','style':'display:inline-block;vertical-align:middle;width:22px;height:22px;flex:none;background:currentColor;-webkit-mask:url("'+url+'") center / contain no-repeat;mask:url("'+url+'") center / contain no-repeat'});
    if(detail) return E('span',{'class':'sbtv-live-icon-detail','aria-hidden':'true','style':'display:inline-flex;align-items:center;gap:2px'},[glyph,E('small',{'style':'font-size:10px'},[detail])]);
    return glyph;
}
// Interruptible animation: polling never restarts an unchanged transition.
function stableText(node,value) {
    if(node.textContent!==value)node.textContent=value;
}
function stableIcon(button,key,make) {
    if(button._renderKey===key)return;
    button._renderKey=key;button.replaceChildren(make());
}
function motionAllowed(node) {
    return typeof node.animate==='function' &&
        !(typeof window.matchMedia==='function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
}
function motionVisible(node,visible,display,collapse) {
    if(node._sbtvVisible===visible)return;
    var previous=node._sbtvVisible, old=node._sbtvAnimation;
    var sampled=old && typeof window.getComputedStyle==='function'?window.getComputedStyle(node):null;
    var opacity=sampled?Number(sampled.opacity):null;
    var currentHeight=sampled && collapse?node.getBoundingClientRect().height:null;
    node._sbtvVisible=visible;
    if(old){old.onfinish=null;old.cancel();node._sbtvAnimation=null;}
    node.inert=!visible;
    if(visible)node.style.display=display;
    if(previous===undefined || !motionAllowed(node)){
        node.style.display=visible?display:'none';return;
    }
    var height=collapse?node.getBoundingClientRect().height:0;
    var from={opacity:0},to={opacity:1};
    if(collapse && height>0){
        from.height='0px';to.height=height+'px';
        from.overflow=to.overflow='hidden';
        from.boxSizing=to.boxSizing='border-box';
    }
    try{
        var frames=visible?[from,to]:[to,from];
        if(opacity!=null && Number.isFinite(opacity))frames[0]={...frames[0],opacity:opacity};
        if(currentHeight!=null && height>0)frames[0].height=currentHeight+'px';
        var anim=node.animate(frames,{duration:visible?200:150,easing:'cubic-bezier(.2,.75,.25,1)'});
        node._sbtvAnimation=anim;
        anim.onfinish=function(){
            if(node._sbtvAnimation!==anim)return;
            node._sbtvAnimation=null;
            if(!node._sbtvVisible)node.style.display='none';
        };
        if(anim.finished)anim.finished.then(anim.onfinish,function(){});
    }catch(e){node.style.display=visible?display:'none';}
}
function animatedDetails(label,children,initialOpen) {
    var body=E('div',{'class':'sbtv-disclosure-body'},children);
    var summary=E('summary',{},[E('span',{},[label]),liveIcon('chevron-down')]);
    var details=E('details',{'class':'sbtv-disclosure'},[summary,body]);
    details.open=!!initialOpen;
    summary.addEventListener('click',function(e){
        if(!motionAllowed(body)){
            if(body._sbtvAnimation){body._sbtvAnimation.onfinish=null;body._sbtvAnimation.cancel();body._sbtvAnimation=null;}
            body._sbtvVisible=undefined;body.inert=false;return;
        }
        e.preventDefault();
        var opening=body._sbtvVisible===false || !details.open;
        if(body._sbtvAnimation){body._sbtvAnimation.onfinish=null;body._sbtvAnimation.cancel();}
        if(opening)details.open=true;
        body._sbtvVisible=opening;body.inert=!opening;
        var h=body.getBoundingClientRect().height;
        var frames=[{height:'0px',opacity:0,overflow:'hidden'},{height:h+'px',opacity:1,overflow:'hidden'}];
        try{
            var anim=body.animate(opening?frames:frames.reverse(),{duration:200,easing:'cubic-bezier(.2,.75,.25,1)'});
            body._sbtvAnimation=anim;
            anim.onfinish=function(){
                if(body._sbtvAnimation!==anim)return;
                body._sbtvAnimation=null;details.open=opening;
            };
            if(anim.finished)anim.finished.then(anim.onfinish,function(){});
        }catch(err){details.open=opening;}
    });
    return details;
}
function createLivePlayer(openAdd) {
	var cards = Object.create(null);
	var summary = E('p', { 'role': 'status', 'aria-live': 'polite' }, [ tr('Waiting for live TV status...') ]);
	var content = E('div', {'class':'sbtv-live-grid'});
    var addAction=E('button',{type:'button','class':'btn cbi-button cbi-button-action','click':openAdd,'aria-label':tr('Add TV')},[liveIcon('plus'),E('span',{},[tr('Add TV')])]);
	var panel = E('section', { 'class': 'cbi-section sbtv-panel sbtv-live-section', 'aria-labelledby':'sbtv-live-title' }, [
        E('div',{'class':'sbtv-section-header'},[E('div',{},[E('h3',{'id':'sbtv-live-title','class':'sbtv-panel-title'},[tr('Live TV control')]),summary]),addAction]),content
	]);
	function timestamp(s) {
		s = Math.max(0, Math.floor(Number(s) || 0));
		var sec = String(s % 60).padStart(2, '0');
		var min = Math.floor(s / 60);
		return min >= 60 ? Math.floor(min / 60) + ':' + String(min % 60).padStart(2, '0') + ':' + sec : min + ':' + sec;
	}
    function savingsDuration(s) {
        s=Number(s);
        s=Number.isFinite(s)?Math.max(0,Math.floor(s)):0;
        return Math.floor(s/3600)+' '+tr('hr')+' '+String(Math.floor(s/60)%60).padStart(2,'0')+' '+tr('min')+' '+String(s%60).padStart(2,'0')+' '+tr('sec');
    }
	function createCard(id) {
		var title = E('strong', {'class':'sbtv-tv-name'}), state = E('span', {'class':'sbtv-tv-status'}), video = E('a', { 'target': '_blank', 'rel': 'noopener noreferrer' });
		var mediaQuality=E('span',{'class':'sbtv-media-quality'});
		var author = E('div', { 'class':'sbtv-author','style': 'opacity:.75;font-size:.9em' });
		var image = E('img', { 'alt': tr('Video thumbnail'), 'referrerpolicy': 'no-referrer', 'style': 'width:clamp(88px,30%,140px);flex:0 0 auto;aspect-ratio:16/9;object-fit:cover;border-radius:6px;display:none' });
		image.addEventListener('error', function() { image.style.display = 'none'; });
		var time = E('span', { 'class':'sbtv-time','style': 'font-variant-numeric:tabular-nums' });
		var seek = E('input', { 'type': 'range', 'min': 0, 'max': 1, 'step': 1, 'aria-label': tr('Playback position'), 'class':'sbtv-seek-input', 'style': 'width:100%' });
		var volume = E('input', { 'type': 'range', 'min': 0, 'max': 100, 'step': 1, 'aria-label': tr('Volume'), 'style': 'width:100%;min-width:0;margin:0' });
		var volText = E('span', {'class':'sbtv-volume-value'}), feedback = E('div', { 'role': 'status', 'aria-live': 'polite', 'style': 'display:none' });
		var current = {}, busy = false, activeButton = null, seekEditing = false, volumeEditing = false, buttons = [];
		async function send(action, value, button, payload) {
			if (busy || current.connection !== 'connected' || current.command_pending) return;
			busy = true; activeButton = button || null;
            clearFeedback(feedback);
            if (button) button.setAttribute('aria-busy', 'true');
			updateControls();
			try {
                var result = await sendLiveCommand(id, action, Math.round(value || 0), payload || '');
                if (!result || !result.accepted) throw new Error(result && result.error || tr('Command rejected'));
                var started = Date.now(), deadline = started + 15000;
                do {
                    var snapshot = await getLiveStatus();
                    var device = (snapshot.devices || []).find(function(d) { return d.id === id; });
                    if (!device || device.connection !== 'connected') throw new Error(tr('TV disconnected'));
                    if (!device.command_pending) {
                        if (device.command_status === 'unconfirmed') throw new Error(tr('TV did not confirm the command.'));
                        if (device.command_status !== 'sent' && !(action === 'dpad' && device.command_status === 'delivered')) throw new Error(tr('Command failed'));
                        update(device);
                        clearFeedback(feedback);
                        return;
                    }
                    await new Promise(function(resolve) { window.setTimeout(resolve, Date.now()-started<2000?150:500); });
                } while (Date.now() < deadline);
                throw new Error(tr('Command not confirmed. Check TV status.'));
            } catch (err) {
                actionFeedback(feedback, err.message || tr('Command failed'), 'error');
            } finally {
                busy = false; activeButton = null;
                if (button) button.removeAttribute('aria-busy');
                updateControls();
            }
		}
		function btn(label, action, value, payload, icon) {
			var b = E('button', { 'type': 'button', 'class': 'btn cbi-button', 'click': function() { return send(typeof action === 'function' ? action() : action, typeof value === 'function' ? value() : value, b, typeof payload === 'function' ? payload() : payload); } }, [label]);
			b._liveLabel = label; b._liveIcon = icon || ({
                previous:'skip-back',next:'skip-forward',back10:'rotate-ccw',forward10:'rotate-cw',
                speed:'gauge',skip_ad:'skip-forward',skip_segment:'skip-forward',
            })[action] || null;
            if(b._liveIcon){b.style.minWidth='44px';b.style.minHeight='44px';b.style.fontSize='1.2em';b.style.padding='6px 10px';}
            buttons.push(b); return b;
		}
		var previous = btn(tr('Previous'), 'previous');
		var playPause = btn(tr('Play'), function() { return [0, 1, 3].indexOf(Number(current.playback)) >= 0 ? 'pause' : 'play'; }, 0, '', 'play');
        var skipAd = btn(tr('Skip ad'), 'skip_ad');
        skipAd.className = 'btn cbi-button cbi-button-action';
        var adTime = E('span', { 'style': 'font-variant-numeric:tabular-nums' });
        var adProgress = E('progress', { 'max': 1, 'aria-label':tr('Advertisement progress'), 'style': 'width:100%;display:block;margin:0;accent-color:#b8860b' });
        var adMarker = E('span',{'class':'sbtv-ad-skip-marker','aria-hidden':'true','style':'display:none;position:absolute;top:0;bottom:0;width:3px;border-radius:2px;background:currentColor;transform:translateX(-50%);pointer-events:none'});
        var adTrack=E('div',{'style':'display:none;position:relative;margin:8px 0'},[adProgress,adMarker]);
        var adSkipText=E('div',{'class':'sbtv-ad-skip-status','style':'font-size:.9em;line-height:1.4'});
        var adBox = E('div', { 'class':'sbtv-ad-box','role': 'status', 'style': 'display:none;border:1px solid #b8860b;border-radius:8px;padding:10px;margin:12px 0' }, [
            E('div', { 'style': 'display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap' }, [E('strong', {}, [tr('Advertisement')]), adTime, skipAd]), adTrack, adSkipText
        ]);
		var next = btn(tr('Next'), 'next');
        var back10 = btn(tr('Back 10 seconds'), 'back10'), forward10 = btn(tr('Forward 10 seconds'), 'forward10');
        var activeSegment = -1;
        var skipSegment = btn(tr('Skip segment'), 'skip_segment', function() { return activeSegment; });
        var segmentKey=null;
        var playedTrack=E('div',{'class':'sbtv-seek-played'});
        var segmentBar=E('div',{'class':'sbtv-seek-segments','aria-hidden':'true'});
        var seekTrack=E('div',{'class':'sbtv-seek-track','aria-hidden':'true'},[playedTrack,segmentBar]);
        var seekWrap=E('div',{'class':'sbtv-seek-wrap'},[seekTrack,seek]);
        var segmentLegend=E('div',{'class':'sbtv-segment-legend','style':'display:none'},[
            E('span',{'data-mode':'skip'},[E('i',{'aria-hidden':'true'}),tr('Skip')])
        ]);
        var segmentList=E('ul',{'class':'sbtv-segment-list'});
        var segmentDetails=E('details',{'class':'sbtv-segment-details','style':'display:none'},[
            E('summary',{},[tr('Segment time ranges')]),segmentList
        ]);
        function updateSeekFill(){
            var min=Number(seek.min),span=Number(seek.max)-min;
            playedTrack.style.width=(span>0?Math.max(0,Math.min(100,100*(Number(seek.value)-min)/span)):0)+'%';
        }
        function updateSegmentMarkers(d){
            var enabled=String((policyCache||d.policy_overrides||{}).skip_sponsorblock)==='1';
            var min=Number(seek.min),max=Number(seek.max),span=max-min;
            var actualEnd=Number(d.seek_end == null ? d.duration : d.seek_end);
            var segments=Number.isFinite(actualEnd) && actualEnd>min && enabled && d.connection==='connected' && !d.ad_active && /^[A-Za-z0-9_-]{11}$/.test(d.video_id||'') && span>0 && Array.isArray(d.segments)?d.segments:[];
            var key=JSON.stringify([d.video_id,min,max,segments]);
            activeSegment=-1;
            // Merge overlapping skip ranges at their exact endpoints.
            // The displayed geometry uses the same DVR bounds as the seek input.
            if(key!==segmentKey){
                segmentKey=key;segmentBar.replaceChildren();segmentList.replaceChildren();
                var ranges=[];
                segments.forEach(function(seg){
                    if(!seg || seg.start==null || seg.end==null)return;
                    var a=Math.max(min,Number(seg.start)),b=Math.min(max,Number(seg.end));
                    if(Number.isFinite(a)&&Number.isFinite(b)&&b>a)ranges.push({start:a,end:b});
                });
                ranges.sort(function(a,b){return a.start-b.start||a.end-b.end;});
                var merged=[];
                ranges.forEach(function(r){
                    var prev=merged[merged.length-1];
                    if(prev && r.start<=prev.end)prev.end=Math.max(prev.end,r.end);
                    else merged.push(r);
                });
                ranges=merged;
                var descriptions=[];
                ranges.forEach(function(r){
                    var label=tr('Skip')+' '+timestamp(r.start)+' \u2013 '+timestamp(r.end);
                    descriptions.push(label);
                    var marker=E('span',{'class':'sbtv-segment-marker','data-mode':'skip','title':label});
                    marker.style.left=(100*(r.start-min)/span)+'%';
                    marker.style.width=(100*(r.end-r.start)/span)+'%';
                    segmentBar.appendChild(marker);
                    segmentList.appendChild(E('li',{'data-mode':'skip'},[E('i',{'aria-hidden':'true'}),label]));
                });
                segmentLegend.style.display=ranges.length?'flex':'none';
                segmentDetails.style.display=ranges.length?'':'none';
                if(!ranges.length)segmentDetails.open=false;
                seek.setAttribute('aria-description',descriptions.join('; '));
            }
            segments.forEach(function(seg,i){
                if(seg && seg.start!=null && seg.end!=null && d.position_known!==false &&
                    d.position>=seg.start && d.position<seg.end && seg.end<=max && seg.end>=min &&
                    (activeSegment<0 || Number(seg.end)>Number(segments[activeSegment].end)))activeSegment=i;
            });
        }
        var policyBusy=false, policyCache=null;
        function storedPolicy(op,key,value){
            var section=current.config_section;
            if(!section || !/^[A-Za-z0-9_]+$/.test(section))return Promise.reject(new Error(tr('TV is not configured')));
            var args=[op,section];if(op==='set')args.push(key,value);
            return fs.exec('/usr/sbin/sponsorblocktv-policy',args).then(function(res){
                var data;try{data=JSON.parse(res.stdout||'{}');}catch(e){throw new Error(tr('Invalid TV policy response'));}
                if(res.code!==0 || !data.policies)throw new Error(data.error||tr('Unable to read or save TV settings'));
                return data;
            });
        }

        var settingsBtn=E('button',{type:'button','class':'btn cbi-button','title':tr('TV settings'),'aria-label':tr('TV settings'),'aria-haspopup':'dialog','style':'margin:0;min-width:44px;min-height:44px','click':function(){
            if(settingsBtn.disabled)return;
            if(current.policy_ready && current.policy_overrides){showPolicy(policyCache||current.policy_overrides);return;}
            policyBusy=true;updateControls();
            return storedPolicy('get').then(function(result){
                policyCache=result.policies;showPolicy(result.policies);
            }).catch(function(err){
                ui.addNotification(null,E('p',{},[err.message||tr('Unable to read TV settings')]),'error');
            }).finally(function(){policyBusy=false;updateControls();});
        }},[liveIcon('settings')]);
        function showPolicy(policies){
            var fields=[
                ['skip_ads',tr('Skip native ads'),tr('Skip ads when allowed by YouTube.')],
                ['mute_ads',tr('Mute native ads'),tr('Mute during ads.')],
                ['auto_play',tr('Autoplay'),tr('Play the next video automatically.')],
                ['skip_sponsorblock',tr('Video segments'),tr('Automatically skip enabled categories.')],
                ['statistics',tr('Statistics'),tr('Collect and display playback statistics for this TV.')]
            ];
            var saved=Object.assign({},policies);
            var status=E('div',{'role':'status','aria-live':'polite','style':'display:none'});
            var controls=[];
            var done=E('button',{type:'button','class':'btn cbi-button','click':function(){if(!policyBusy)ui.hideModal();}},[tr('Done')]);
            async function change(key,input){
                var value=input.value,previous=saved[key];
                if(policyBusy){input.value=previous;return;}
                if(value===previous)return;
                policyBusy=true;controls.forEach(function(c){c.input.disabled=true;if(c.lock)c.lock(true);});done.disabled=true;
                actionFeedback(status,tr('Saving...'),'busy');
                try{
                    var result;
                    if(current.policy_ready){
                        try{
                            result=await saveLivePolicy(id,key,value);
                            if(result && result.error==='Unknown device')result=await storedPolicy('set',key,value);
                        }catch(err){
                            if(!/Object not found|Resource not found|ubus code 4/i.test(err.message||''))throw err;
                            result=await storedPolicy('set',key,value);
                        }
                    }else result=await storedPolicy('set',key,value);
                    if(!result || !result.saved || !result.policies)throw new Error(result&&result.error||tr('Unable to save TV settings'));
                    saved=Object.assign({},result.policies);policyCache=saved;
                    controls.forEach(function(c){c.input.value=saved[c.key];if(c.sync)c.sync();});
                    syncSegmentOptions();
                    updateSegmentMarkers(current);
                    updateStats(current);
                    clearFeedback(status);
                }catch(err){
                    input.value=previous;
                    controls.forEach(function(c){if(c.sync)c.sync();});
                    actionFeedback(status,err.message||tr('Unable to save TV settings'),'error');
                }finally{
                    policyBusy=false;controls.forEach(function(c){c.input.disabled=false;if(c.lock)c.lock(false);});done.disabled=false;updateControls();
                }
            }
            controls=fields.map(function(f){
                var input=E('select',{'class':'cbi-input-select','aria-label':f[1],'style':'width:100%;margin:4px 0 0','change':function(){return change(f[0],input);}},[
                    E('option',{value:'1'},[tr('On')]),E('option',{value:'0'},[tr('Off')])
                ]);
                input.value=saved[f[0]]||'0';
                return {key:f[0],input:input,row:E('div',{'class':'sbtv-policy-row'},[E('div',{},[E('strong',{},[f[1]]),E('div',{'class':'cbi-section-descr'},[f[2]])]),input])};
            });
            var mode=E('select',{'class':'cbi-input-select','aria-label':tr('Controller mode'),'style':'width:100%;margin:4px 0 0','change':function(){return change('controller_mode',mode);}},[
                E('option',{value:'cooperative'},[tr('Cooperative')]),E('option',{value:'standard'},[tr('Standard')]),E('option',{value:'passive'},[tr('Passive')])
            ]);
            mode.value=saved.controller_mode||'cooperative';
            var modeDescriptions={
                cooperative:tr('Prioritize other remotes; keep auto-skip enabled.'),
                standard:tr('Apply TV settings without remote priority.'),
                passive:tr('Monitor only; no control commands.')
            };
            var modeDescription=E('div',{'class':'cbi-section-descr','aria-live':'polite'});
            function syncMode(){stableText(modeDescription,modeDescriptions[mode.value]||modeDescriptions.cooperative);}
            syncMode();
            controls.unshift({key:'controller_mode',input:mode,sync:syncMode,row:E('div',{'class':'sbtv-policy-row sbtv-policy-mode'},[E('div',{},[E('strong',{},[tr('Controller mode')]),modeDescription]),mode])});
            var catValue={value:saved.skip_categories||'none',disabled:false};
            function saveCats(){
                if(policyBusy){syncCats();return;}
                catValue.value=catInputs.filter(function(x){return x.enabled.checked;}).map(function(x){return x.key;}).join(',')||'none';
                return change('skip_categories',catValue);
            }
            var catInputs=CATEGORIES.map(function(c){
                var enabled=E('input',{type:'checkbox','aria-label':tr('Enable category')+': '+c[1],'change':saveCats});
                return {key:c[0],enabled:enabled,row:E('label',{'style':'display:flex;align-items:center;gap:8px;padding:6px 0'},[enabled,E('span',{},[c[1]])])};
            });
            function syncCats(){
                var selected=String(saved.skip_categories||'none').split(',');
                catInputs.forEach(function(c){
                    c.enabled.checked=selected.indexOf(c.key)>=0;
                    c.enabled.disabled=policyBusy;
                });
            }
            syncCats();
            controls.push({key:'skip_categories',input:catValue,sync:syncCats,lock:function(b){catInputs.forEach(function(x){x.enabled.disabled=b;});},row:animatedDetails(tr('Segment categories'),[E('div',{},catInputs.map(function(c){return c.row;}))],false)});
            var minimum=E('input',{type:'number',min:'0',max:'604800',step:'1','class':'cbi-input-text','aria-label':tr('Minimum segment length'),'style':'width:100%;margin:4px 0 0','change':function(){
                if(!/^(0|[1-9][0-9]{0,5})$/.test(minimum.value) || Number(minimum.value)>604800){
                    minimum.value=saved.minimum_skip_length;actionFeedback(status,tr('Enter a whole number from 0 to 604800.'),'error');return;
                }
                return change('minimum_skip_length',minimum);
            }});
            minimum.value=saved.minimum_skip_length;
            controls.push({key:'minimum_skip_length',input:minimum,row:E('div',{'class':'sbtv-policy-row'},[E('strong',{},[tr('Minimum segment length (seconds)')]),minimum])});
            var segmentOptions=E('div',{'class':'sbtv-segment-options'},controls.filter(function(c){return c.key==='skip_categories'||c.key==='minimum_skip_length';}).map(function(c){return c.row;}));
            function syncSegmentOptions(){
                var enabled=String(saved.skip_sponsorblock)==='1';
                segmentOptions.style.display=enabled?'':'none';
                segmentOptions.setAttribute('aria-hidden',enabled?'false':'true');
            }
            syncSegmentOptions();
            ui.showModal(tr('TV settings')+' - '+(current.name||tr('YouTube TV')),[
                E('p',{'class':'cbi-section-descr'},[tr('Changes apply only to this TV and save immediately.')]),
                E('div',{'class':'sbtv-policy-modal sbtv-enter'},controls.filter(function(c){return c.key!=='skip_categories'&&c.key!=='minimum_skip_length';}).map(function(c){return c.row; }).concat([segmentOptions])),status,
                E('div',{'class':'button-row sbtv-modal-footer'},[done])
            ]);
        }
        var remoteOpen=false;
        var qualityLabels={tiny:'144p',small:'240p',medium:'360p',large:'480p',hd720:'720p',hd1080:'1080p',hd1440:'1440p',hd2160:'2160p',hd2880:'2880p',highres:tr('High resolution'),auto:tr('Auto'),default:tr('Auto')};
        function formatQuality(q) {
            if(typeof q==='string' && /^(144|240|360|480|720|1080|1440|2160|2880|4320)$/.test(q))return q+'p';
            return typeof q==='string' && Object.prototype.hasOwnProperty.call(qualityLabels,q) ? qualityLabels[q] : (typeof q==='string' && q ? q : tr('Unknown'));
        }
        var remoteToggle = E('button',{type:'button','class':'btn cbi-button','aria-label':tr('YouTube remote'),'title':tr('YouTube remote'),'aria-expanded':'false','click':function(){
            if(remoteToggle.disabled)return;
            remoteOpen=!remoteOpen;updateControls();
        }},[liveIcon('keyboard')]);
        remoteToggle._liveLabel=tr('YouTube remote');remoteToggle._liveIcon='keyboard';buttons.push(remoteToggle);
        var remoteKeys = [['UP','chevron-up',2,1],['LEFT','chevron-left',1,2],['ENTER','check',2,2],['RIGHT','chevron-right',3,2],['DOWN','chevron-down',2,3],['BACK','undo-2',1,3]].map(function(k){
            var key = btn(tr({UP:'Up',DOWN:'Down',LEFT:'Left',RIGHT:'Right',ENTER:'OK',BACK:'Back'}[k[0]]),'dpad',0,k[0],k[1]);
            key.style.gridColumn=String(k[2]);key.style.gridRow=String(k[3]);key.style.margin='0';
            return key;
        });
        var remotePanel=E('div',{'class':'sbtv-tool-panel','style':'display:none;grid-template-columns:repeat(3,minmax(0,1fr));gap:6px;margin:8px auto;max-width:240px'},remoteKeys);

        var info = E('div', {'class':'cbi-section-descr sbtv-live-info'});
        var statsTitle=E('strong',{'class':'sbtv-stats-title'});
        var statValues={};
        function statCell(key,label){
            var value=E('strong',{'class':'sbtv-stat-value','data-stat':key},['0']);
            statValues[key]=value;
            return E('div',{'class':'sbtv-stat-cell'},[E('span',{'class':'sbtv-stat-label'},[label]),value]);
        }
        function statGroup(label,skipKey,muteKey){
            var cells=[statCell(skipKey,tr('Skipped'))];
            if(muteKey)cells.push(statCell(muteKey,tr('Muted')));
            return E('div',{'class':'sbtv-stat-group'},[
                E('strong',{'class':'sbtv-stat-group-title'},[label]),
                E('div',{'class':'sbtv-stat-grid'},cells)
            ]);
        }
        var statBody=E('div',{'class':'sbtv-stat-body'},[
            statGroup(tr('YouTube Ads'),'ad_skips','ad_mutes'),
            statGroup(tr('Video segments'),'skips'),
            E('div',{'class':'sbtv-stat-total'},[
                E('span',{},[tr('Total savings')]),
                statValues.total_seconds=E('strong',{'class':'sbtv-stat-value','data-stat':'total_seconds'},[savingsDuration(0)])
            ])
        ]);
        var stats=E('div',{'class':'sbtv-statistics','style':'display:none'},[statsTitle,statBody]);
        function updateStats(d){
            var totals=d.lifetime_stats||d.segment_stats;
            var enabled=String((policyCache||d.policy_overrides||{}).statistics)==='1';
            stats.style.display=enabled?'':'none';
            if(!enabled)return;
            statBody.style.display=totals?'':'none';
            stableText(statsTitle,totals?(d.lifetime_stats?tr('Lifetime statistics'):tr('Session statistics')):tr('Statistics unavailable'));
            if(!totals)return;
            ['ad_skips','ad_mutes','skips'].forEach(function(k){
                stableText(statValues[k],String(Math.max(0,Math.floor(Number(totals[k])||0))));
            });
            stableText(statValues.total_seconds,savingsDuration(totals.total_seconds==null?(Number(totals.seconds)||0)+(Number(totals.ad_seconds)||0):totals.total_seconds));
        }
		var mute = btn(tr('Mute'), 'mute', function() { return current.muted ? 0 : 1; }, '', 'volume-x');
		seek.addEventListener('input', function() { seekEditing = true; updateSeekFill(); time.textContent = timestamp(seek.value) + ' / ' + timestamp(current.duration); });
		seek.addEventListener('change', function() { seekEditing = false; return send('seek', Number(seek.value)); });
		seek.addEventListener('blur', function() { seekEditing = false; });
		volume.addEventListener('input', function() { volumeEditing = true; volText.textContent = volume.value + '%'; });
		volume.addEventListener('change', function() { volumeEditing = false; return send('volume', Number(volume.value)); });
		volume.addEventListener('blur', function() { volumeEditing = false; });
		function updateControls() {
			var disabled = current.connection !== 'connected' || busy || current.command_pending || (policyCache||current.policy_overrides||{}).controller_mode==='passive';
            settingsBtn.disabled=policyBusy || !(current.policy_ready===true || (sbtvCoreReady && /^[A-Za-z0-9_]+$/.test(current.config_section||'')));
			buttons.forEach(function(b) {
                b.disabled = !!disabled;
                var label = b._liveLabel;
                b.setAttribute('title', label); b.setAttribute('aria-label', label);
                var pending=b===activeButton, adPending=b===skipAd && current.ad_active && current.ad_skip_pending;
                stableIcon(b,JSON.stringify([b._liveIcon,label,pending,adPending]),function(){
                    if(pending)return E('span',{'class':'sbtv-action-spinner','aria-hidden':'true'});
                    var symbol=b._liveIcon?liveIcon(b._liveIcon,(b===back10||b===forward10)?'10':null):E('span',{},[label]);
                    return adPending?E('span',{'class':'sbtv-pending-icon'},[E('span',{'class':'sbtv-action-spinner','aria-hidden':'true'}),symbol]):symbol;
                });
            });
			var inAd = current.connection === 'connected' && !!current.ad_active;
            playPause.disabled = !!disabled || inAd || [-2, -1].indexOf(Number(current.playback)) >= 0;
            previous.disabled = !!disabled || inAd || !current.video_id || current.has_previous !== true || !!current.auto_seek_pending;
            next.disabled = !!disabled || inAd || !current.video_id || current.has_next !== true || !!current.auto_seek_pending;
            skipAd.style.display = inAd && (current.ad_can_skip || activeButton === skipAd) ? '' : 'none';
            skipAd.disabled = !!disabled || !current.ad_can_skip || !!current.ad_skip_pending || !!current.ad_skip_cooldown;
            seek.disabled = !!disabled || inAd || !!current.auto_seek_pending || current.position_known === false || !((current.seek_end == null ? current.duration : current.seek_end) > (current.seek_start || 0));
            back10.disabled = forward10.disabled = seek.disabled;
            skipSegment.disabled = seek.disabled || activeSegment < 0;
            skipSegment.style.display = activeSegment >= 0 && !inAd ? '' : 'none';
            if(current.connection!=='connected' || inAd)remoteOpen=false;
            remoteToggle.disabled=!!disabled || inAd || !!current.auto_seek_pending;
            remoteKeys.forEach(function(k){k.disabled=remoteToggle.disabled;});
            motionVisible(remotePanel,remoteOpen,'grid',true);
            remoteToggle.setAttribute('aria-expanded',remoteOpen?'true':'false');
			volume.disabled = !!disabled || current.volume < 0 || !!current.muted || !!current.mute_busy;
            volume.style.accentColor = current.muted ? '#9ca3af' : '';
            volume.style.filter = current.muted ? 'grayscale(1)' : '';
            volume.style.opacity = current.muted ? '0.55' : '';
            volText.style.opacity = current.muted ? '0.55' : '';
            volume.setAttribute('aria-label', current.muted ? tr('Volume (muted)') : tr('Volume'));
            mute.setAttribute('aria-pressed', current.muted ? 'true' : 'false');
			mute.disabled = !!disabled || current.volume < 0 || current.mute_known===false || !!current.mute_busy;
		}
        var controllerLabel=E('span',{'class':'sbtv-controller-label'});
        var controllerList=E('div',{'class':'sbtv-controller-list'});
        var controllerAge=E('div',{'class':'sbtv-controller-event'});
        var controllerActivity=E('div',{'class':'sbtv-controller-activity'});
        var controllerNotice=E('div',{'class':'sbtv-controller-notice'});
        var controllerDetails=animatedDetails(controllerLabel,[controllerList,controllerAge,controllerActivity,controllerNotice],false);
        controllerDetails.setAttribute('data-role','controllers');
        var controllersKey='';
        function controllerName(r){return (r.name||tr('Unnamed controller'))+(r.self?' ('+tr('This service')+')':'');}
        function updateControllers(d){
            var known=d.connection==='connected' && Array.isArray(d.controllers) && Number.isInteger(d.controller_count);
            controllerDetails.style.display=d.connection==='connected'?'':'none';
            stableText(controllerLabel,known?tr('Controllers')+' ('+d.controller_count+')':tr('Controllers')+' ? '+tr('Not reported'));
            var list=known?d.controllers:[], changes=known&&Array.isArray(d.controller_changes)?d.controller_changes:[];
            var key=JSON.stringify([known,list,changes.map(function(r){return [r.kind,r.name,r.self];})]);
            if(key!==controllersKey){
                controllersKey=key;
                controllerList.replaceChildren.apply(controllerList,list.length?list.map(function(r){
                    return E('div',{'class':'sbtv-controller-row'},[liveIcon('keyboard'),E('span',{},[controllerName(r)])]);
                }):[E('p',{'class':'sbtv-controller-empty'},[known?tr('No remote controllers reported'):tr('Waiting for TV controller list')])]);
                controllerActivity.replaceChildren.apply(controllerActivity,changes.slice(-4).reverse().map(function(r){
                    return E('div',{'class':'sbtv-controller-event'},[r.kind==='joined'?tr('Joined')+': ':tr('Left')+': ',controllerName(r)]);
                }));
            }
            stableText(controllerAge,known&&Number.isFinite(d.controller_age)?tr('Last reported:')+' '+(d.controller_age<60?d.controller_age+'s':Math.floor(d.controller_age/60)+'m')+' '+tr('ago'):'');
            var conflict=known&&d.controller_conflict&&d.controller_conflict.age<=120;
            stableText(controllerNotice,conflict?tr('Possible control conflict: command not confirmed.'):(known&&d.controller_count>1?(d.policy_overrides&&d.policy_overrides.controller_mode==='cooperative'?tr('Other remotes have priority.'):tr('Multiple controllers may send conflicting commands.')):''));
            controllerNotice.style.display=controllerNotice.textContent?'':'none';
        }
        var connectedBody = E('div',{'class':'sbtv-live-body','hidden':true,'style':'display:none'},[
			E('div', { 'class':'sbtv-media','style': 'display:flex;gap:12px;align-items:flex-start' }, [image, E('div', { 'style': 'flex:1;min-width:0;overflow-wrap:anywhere' }, [video, E('div',{'class':'sbtv-media-meta'},[author,mediaQuality])])]),
			adBox, E('div', { 'class':'sbtv-timeline','style': 'margin-top:10px' }, [seekWrap, E('div', {'class':'sbtv-time-row','style':'display:flex;align-items:center;justify-content:space-between;gap:8px;min-height:1.5em;font-size:.9em'},[time,skipSegment]),segmentLegend,segmentDetails]),
			E('div', { 'class':'sbtv-transport','style': 'display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:6px;margin:8px 0' }, [previous, back10, playPause, forward10, next]),
			E('div', { 'class':'sbtv-volume','style': 'display:grid;grid-template-columns:auto minmax(0,1fr) auto auto;align-items:center;gap:8px' }, [mute, volume, volText, remoteToggle]),
            remotePanel,info,controllerDetails,
            stats, feedback
        ]);
        connectedBody.inert=true;
		var node = E('div', { 'class':'sbtv-live-card sbtv-enter','data-connected':'false', 'style': 'border:1px solid rgba(128,128,128,.35);border-radius:10px;padding:12px;margin:12px 0;min-width:0;overflow-wrap:anywhere' }, [
			E('div',{'class':'sbtv-tv-header'},[E('div',{'class':'sbtv-tv-heading'},[liveIcon('monitor'),E('div',{'class':'sbtv-tv-heading-text'},[title,state])]),settingsBtn]),
            connectedBody
        ]);
		function update(d) {
			current = d;
            updateControllers(d);
            if(!policyBusy && d.policy_overrides)policyCache=Object.assign({},d.policy_overrides);
			stableText(title,d.name || tr('YouTube TV'));
			var connected = d.connection === 'connected';
			var phases = { connected: tr('Connected'), connecting: tr('Connecting...'), reconnecting: tr('Reconnecting...'), checking: tr('Checking connection...'), network_error: tr('Network error'), offline: tr('Offline / YouTube unavailable'), auth_error: tr('Authentication error'), unavailable: tr('Live status unavailable'), inactive: tr('Not loaded by runtime') };
			var playback = { '-2': tr('Unknown'), '-1': tr('Idle'), '0': tr('Buffering'), '1': tr('Playing'), '2': tr('Paused'), '3': tr('Starting'), '5': tr('Ready'), '1081': tr('Advertisement') };
			stableText(state,(phases[d.connection] || tr('Unknown')) + (connected && Number(d.playback)!==-2 && playback[d.playback] ? ' \u00b7 ' + playback[d.playback] : ''));
            state.setAttribute('data-connected',connected?'true':'false');
            node.setAttribute('data-connected',connected?'true':'false');
            connectedBody.hidden=!connected;
            connectedBody.inert=!connected;
            connectedBody.style.display=connected?'':'none';
            if(!connected){seekEditing=false;volumeEditing=false;}

			state.style.color = connected ? '#25803b' : '#a16207';
			var vid = connected && /^[A-Za-z0-9_-]{11}$/.test(d.video_id || '') ? d.video_id : '';
			stableText(video,vid ? (d.title || vid) : tr('No active video'));
            node.setAttribute('data-has-video',vid?'true':'false');
			if (vid) video.href = 'https://www.youtube.com/watch?v=' + vid;
			else video.removeAttribute('href');
			stableText(author,vid ? (d.author || '') : '');
			if (image._vid !== vid) {
				image._vid = vid;
				image.style.display = vid ? 'block' : 'none';
				if (vid) image.src = 'https://i.ytimg.com/vi/' + vid + '/hqdefault.jpg';
				else image.removeAttribute('src');
			}
			seek.min = d.seek_start || 0;
			seek.max = Math.max(Number(seek.min)+1,d.seek_end == null ? d.duration || 0 : d.seek_end);
			if (!seekEditing && !busy) { seek.value = d.position || 0; time.textContent = (d.position_known === false ? '--:--' : timestamp(d.position)) + ' / ' + timestamp(d.duration); }
            updateSeekFill();
			if (!volumeEditing) { volume.value = Math.max(0, d.volume || 0); volText.textContent = connected && d.volume >= 0 ? d.volume + '%' : '\u2014';
                volText.setAttribute('aria-label',connected && d.volume>=0?d.volume+'%':tr('Unknown volume')); }
			mute._liveLabel = d.mute_busy ? tr('Waiting for advertisement mute') : d.mute_known===false ? tr('Mute status unknown') : d.muted ? tr('Unmute') : tr('Mute');
            mute._liveIcon = d.muted ? 'volume-2' : 'volume-x';
            playPause._liveLabel = [0, 1, 3].indexOf(Number(d.playback)) >= 0 ? tr('Pause') : tr('Play');
            playPause._liveIcon = [0, 1, 3].indexOf(Number(d.playback)) >= 0 ? 'pause' : 'play';
            var inAd = connected && !!d.ad_active;
            node.setAttribute('data-ad-active',inAd?'true':'false');
            motionVisible(adBox,inAd,'',true);
            var knownPosition = d.ad_position != null && Number.isFinite(Number(d.ad_position)) && d.ad_position >= 0;
            var knownDuration = d.ad_duration != null && Number(d.ad_duration) > 0;
            adTime.textContent = (knownPosition ? timestamp(d.ad_position) : '--:--') + ' / ' + (knownDuration ? timestamp(d.ad_duration) : '--:--');
            adTrack.style.display = inAd && knownPosition && knownDuration ? '' : 'none';
            var markerKnown=inAd && knownDuration && d.ad_skip_at!=null && Number.isFinite(Number(d.ad_skip_at)) && d.ad_skip_at>=0 && d.ad_skip_at<=d.ad_duration;
            adMarker.style.display=markerKnown?'block':'none';
            if(markerKnown){
                adMarker.style.left=(100*Number(d.ad_skip_at)/Number(d.ad_duration))+'%';
                adMarker.style.opacity=d.ad_skip_estimated?'.65':'1';
            }
            var pending=!!d.ad_skip_pending, skipIn=d.ad_skip_in;
            if(!inAd)adSkipText.textContent='';
            else if(pending)adSkipText.textContent=tr('Skipping advertisement...');
            else if(d.ad_can_skip)adSkipText.textContent=tr('Skip available now');
            else if(d.ad_skippable===false)adSkipText.textContent=tr('Cannot skip this advertisement');
            else if(d.ad_skip_estimated && skipIn!=null && Number.isFinite(Number(skipIn)) && Number(skipIn)>0)
                adSkipText.textContent=tr('Estimated skip in:')+' '+Math.ceil(Number(skipIn))+'s';
            else if(d.ad_skippable===true)adSkipText.textContent=tr('Waiting for TV to enable Skip');
            else adSkipText.textContent=tr('Skip availability unknown');
            adProgress.setAttribute('aria-label',tr('Advertisement progress')+(inAd?' - '+adSkipText.textContent:''));
            if (knownDuration && knownPosition) { adProgress.max = Number(d.ad_duration); adProgress.value = Math.min(Number(d.ad_position), Number(d.ad_duration)); }
			
			activeSegment = -1;
            updateStats(d);
            updateSegmentMarkers(d);
            var qualityLabel = formatQuality(d.quality);
            if (!connected || inAd || !vid) qualityLabel=tr('Unknown');
            stableText(mediaQuality,connected && !inAd && vid && d.quality ? qualityLabel : '');
            mediaQuality.style.display=mediaQuality.textContent?'':'none';
            stableText(info,d.up_next ? tr('Up next')+': '+d.up_next : '');
            info.style.display = info.textContent ? 'block' : 'none';
            updateControls();
        }
        return { node: node, update: update };
	}
	function renderDevices(devices) {
		var seen = Object.create(null);
		devices.forEach(function(d) {
			if (!d.id) return;
			seen[d.id] = true;
			if (!cards[d.id]) { cards[d.id] = createCard(d.id); content.appendChild(cards[d.id].node); }
			cards[d.id].update(d);
		});
		Object.keys(cards).forEach(function(id) { if (!seen[id]) { cards[id].node.remove(); delete cards[id]; } });
	}
	function configuredDevices(phase) {
		return (uci.sections('sponsorblocktv', 'device') || []).filter(function(d) { return !!(d.screen_id || '').trim(); }).map(function(d, i) {
			return { id: 'configured-' + (d['.name'] || i), config_section:d['.name'], name: d.name || tr('YouTube TV'), connection: phase, volume: -1, playback: -1, position: 0, duration: 0 };
		});
	}
	function refresh() {
        if(document.hidden===true)return Promise.resolve();
		if (!configuredDevices('inactive').length) {
			summary.textContent = tr('Add a TV to start.');
			addAction.style.display='';
			renderDevices([]);
			return Promise.resolve();
		}
		addAction.style.display='';
		return getLiveStatus().then(function(result) {
			if (!result || !Array.isArray(result.devices)) throw new Error(tr('Invalid live API response'));
			var devices = result.devices.slice();
			var configured = configuredDevices('inactive');
			if (!devices.length) {
				summary.textContent = configured.length ? tr('Restart the service to load paired TVs.') : tr('Add a TV first.');
				renderDevices(configured);
				return;
			}
			configured.forEach(function(d){if(!devices.some(function(l){return l.config_section===d.config_section;}))devices.push(d);});
			stableText(summary,devices.filter(function(d) { return d.connection === 'connected'; }).length + '/' + devices.length + ' ' + tr('TVs connected'));
			renderDevices(devices);
		}).catch(function(err) {
			if (/Object not found|Resource not found|ubus code 4/i.test(err.message || '')) {
				summary.textContent = tr('Waiting for the service to start.');
				renderDevices(configuredDevices('inactive'));
			} else {
				summary.textContent = tr('Live status unavailable: ') + (err.message || tr('Unknown error'));
				renderDevices(configuredDevices('unavailable'));
			}
		});
	}
	return { panel: panel, refresh: refresh };
}

var categoryLabels = [
	[ 'sponsor',          'Sponsor' ],
	[ 'selfpromo',        'Self Promotion' ],
	[ 'intro',            'Intro' ],
	[ 'outro',            'Outro' ],
	[ 'music_offtopic',   'Music Offtopic' ],
	[ 'interaction',      'Interaction' ],
	[ 'exclusive_access', 'Exclusive Access' ],
	[ 'preview',          'Preview/Recap' ],
	[ 'filler',           'Filler' ],
	[ 'hook',             'Hook/Greetings' ]
];
var CATEGORIES=categoryLabels.slice();

var sbtvCoreReady = false;
var pendingCheck, modal, mapNode, afterInstall, lastHealthyCheck=0;
var installer = '/usr/sbin/sponsorblocktv-install-deps';

function execOutput(path, args) {
	return fs.exec(path, args).then(function(result) {
		if (result.code !== 0)
			throw new Error([ result.stderr, result.stdout ].filter(Boolean).join('\n') || tr('Command failed'));
		return (result.stdout || '').trim();
	});
}

function checkCoreDeps() {
    if(sbtvCoreReady && Date.now()-lastHealthyCheck<60000)return Promise.resolve(true);
    if (!pendingCheck)
        pendingCheck = fs.exec('/usr/sbin/sponsorblocktv-deps', []).then(function(result) {
            var output = (result.stdout || '').trim();
            var lines = output.split(/\r?\n/).filter(Boolean);
            var missing = lines.filter(function(line) { return /^MISSING [A-Za-z0-9_.+-]+$/.test(line); });
            if (result.code !== 0) {
                sbtvCoreReady = false;
                if (mapNode) mapNode.inert = true;
                showDependencyCheckError([result.stderr, output].filter(Boolean).join('\n') || tr('Dependency check failed'));
                return false;
            }
            if (missing.length !== lines.length) {
                sbtvCoreReady = false;
                if (mapNode) mapNode.inert = true;
                showDependencyCheckError(output || tr('Unexpected dependency check response'));
                return false;
            }
            sbtvCoreReady = missing.length === 0;
            if(sbtvCoreReady)lastHealthyCheck=Date.now();
            var depFeedback = document.getElementById('sbtv-dependency-feedback');
            if (depFeedback) { depFeedback.replaceChildren(); depFeedback.style.display = 'none'; }
            if (mapNode) mapNode.inert = !sbtvCoreReady;
            if (missing.length) showDependencies(missing.join('\n'));
            return sbtvCoreReady;
        }).catch(function(err) {
            sbtvCoreReady = false;
            if (mapNode) mapNode.inert = true;
            showDependencyCheckError(err.message);
            return false;
        }).finally(function() { pendingCheck = null; });
    return pendingCheck;
}

function showDependencyCheckError(message) {
    var status = document.getElementById('sbtv-dependency-feedback');
    if (modal && modal.isConnected) {
        modal.textContent = tr('Package check failed: ') + message;
        modal.style.display = 'block';
    } else if (status) {
        actionFeedback(status, tr('Package check failed: ') + message, 'error');
    } else {
        ui.addNotification(null, E('p', {}, [ tr('Package check failed: '), message ]), 'error');
    }
}

function showDependencies(message) {
    var missingPackages = message.split(/\r?\n/).filter(function(line) { return /^MISSING [A-Za-z0-9_.+-]+$/.test(line); }).map(function(line) { return line.slice(8); });
    message = missingPackages.length ? tr('Missing packages (%d):').format(missingPackages.length) + '\n' + missingPackages.map(function(pkg) { return '\u2022 ' + pkg; }).join('\n') : message;
	if (modal && modal.isConnected) { modal.textContent = message; modal.style.display = message ? 'block' : 'none'; return; }
	var details = modal = E('pre', { 'style': 'white-space:pre-wrap;max-height:14em;overflow:auto;display:' + (message ? 'block' : 'none') }, [ message ]);
	var stage = E('strong', {}, []);
	var bar = E('progress', { 'aria-label': tr('Installation progress') });
	var elapsed = E('small');
	var progress = E('div', { 'hidden': true, 'style': 'padding:14px 0' }, [ E('span', { 'class': 'sbtv-install-spinner', 'style': 'display:inline-block;width:16px;height:16px;border:3px solid #aaa;border-top-color:#1676c2;border-radius:50%;animation:sbtv-spin .8s linear infinite;vertical-align:middle;margin-right:10px' }), stage, E('div', { 'style': 'margin-top:12px' }, [ bar ]), E('div', { 'style': 'margin-top:8px' }, [ elapsed ]) ]);
	var busy = false;
	bar.removeAttribute('value');
	bar.style.width = '100%';
	var button = E('button', { 'type':'button', 'class':'btn cbi-button-action', 'style':'display:inline-block;margin-top:18px', 'click': start }, [ tr('Install required packages') ]);
	function wait() { return new Promise(function(resolve) { window.setTimeout(resolve, 1000); }); }
	async function start(event, attach) {
		if (busy) return;
		busy = button.disabled = true;
		progress.hidden = bar.hidden = false;
		details.textContent = '';
		details.style.display = 'none';
		button.textContent = tr('Installing...' );
		var since = Date.now();
		var clock = window.setInterval(function() { elapsed.textContent = tr('Elapsed: %ds').format(Math.floor((Date.now()-since)/1000)); }, 500);
		try {
			stage.textContent = tr('Starting installation');
			if (!attach) await execOutput(installer, [ 'core' ]);
			for (;;) {
				var state = await execOutput(installer, [ 'status' ]);
				if (state === 'DONE') break;
				if (!state.startsWith('RUN ')) throw new Error(state);
				stage.textContent = state.slice(4);
				await wait();
			}
			stage.textContent = tr('Verifying installed packages');
			if (!await checkCoreDeps()) throw new Error(details.textContent || tr('Verification failed'));
			if (afterInstall) { await afterInstall(); afterInstall = null; }
			ui.hideModal(); modal = null;
			await updateControlButtons();
		} catch (err) {
			stage.textContent = tr('Installation failed');
			details.textContent = err.message;
			details.style.display = 'block';
			button.textContent = tr('Retry');
		} finally {
			window.clearInterval(clock);
			progress.hidden = bar.hidden = true;
			busy = button.disabled = false;
		}
	}
	ui.showModal(tr('Required packages are missing'), [E('style', {}, [ '@keyframes sbtv-spin { to { transform:rotate(360deg); } }' ]), details, progress, E('div',{'class':'button-row sbtv-modal-footer'},[button])]);
	execOutput(installer, ['status']).then(function(state) {
		if (state.startsWith('RUN ') && modal === details && !busy) start(null, true);
	}).catch(function(err) { details.textContent += '\n' + err.message; });
}
var controlTimer, controlRequest = 0, controlBusy = false, healthBusy = false;
async function checkLiveDependencies() {
    if (healthBusy || !mapNode || !mapNode.isConnected) return;
    healthBusy = true;
    try {
        await checkCoreDeps();
    } catch (err) { console.warn('SponsorBlockTV dependency check failed', err); }
    finally { healthBusy = false; }
}


function refreshEnableButton() {
    var button = document.getElementById('sbtv-control-enable');
    var section = (uci.sections('sponsorblocktv', 'sponsorblocktv') || [])[0];
    if (!button || !section) return;
    var enabled = uci.get('sponsorblocktv', section['.name'], 'enabled') === '1';
    button.disabled = controlBusy;
    button.textContent = enabled ? tr('Disable') : tr('Enable');
    button.className = enabled ? 'btn cbi-button cbi-button-reset sbtv-control-button' : 'btn cbi-button cbi-button-action sbtv-control-button';
    button.style.opacity = '1';
    button.title = enabled ? tr('Disable autostart (Save & Apply)') : tr('Enable autostart (Save & Apply)');
}

function setControlsChecking(checking) {
    ['enable', 'start', 'stop', 'restart'].forEach(function(action) {
        var button = document.getElementById('sbtv-control-' + action);
        if (!button) return;
        if (checking) {
            button.disabled = true;
            button.style.opacity = '0.45';
        } else if (action === 'enable') {
            refreshEnableButton();
        }
    });
}
function lockControls() {
	['enable', 'start', 'stop', 'restart'].forEach(function(action) {
		var button = document.getElementById('sbtv-control-' + action);
		if (button) button.disabled = true;
	});
}

async function serviceAction(action) {
    if (!sbtvCoreReady || controlBusy) return;
    if (action !== 'stop' && !(uci.sections('sponsorblocktv', 'device') || []).some(function(d) { return !!(d.screen_id || '').trim(); })) {
        actionFeedback(document.getElementById('sbtv-action-feedback'), tr('Add a TV before starting the service.'), 'error');
        return;
    }
    controlBusy = true;
    ++controlRequest;
    window.clearTimeout(controlTimer);
    lockControls();
    var button = document.getElementById('sbtv-control-' + action);
    var status = document.getElementById('sbtv-control-status');
    var label = button ? button.textContent : '';
    var labels = { start: tr('Starting...'), stop: tr('Stopping...'), restart: tr('Restarting...') };
    if (button) {
        button.textContent = labels[action];
        button.style.opacity = '0.7';
        button.style.cursor = 'wait';
        button.style.setProperty('animation', 'sbtv-control-pulse 1s ease-in-out infinite');
    }
    if (button) button.setAttribute('aria-busy', 'true');
    actionFeedback(document.getElementById('sbtv-action-feedback'), labels[action], 'busy');
    if (status) status.textContent = labels[action];
    var failed = false;
    try {
        await execOutput('/etc/init.d/sponsorblocktv', [ action ]);
    } catch (err) {
        failed = true;
        actionFeedback(document.getElementById('sbtv-action-feedback'), err.message || tr('Action failed'), 'error');
        if (status) status.textContent = tr('Action failed');
    } finally {
        if (button) {
            button.textContent = label;
            button.style.removeProperty('animation');
            button.style.removeProperty('cursor');
            button.removeAttribute('aria-busy');
        }
        controlBusy = false;
    }
    var running = await updateControlButtons();
    if (!failed) {
        var confirmed = running === (action !== 'stop');
        actionFeedback(document.getElementById('sbtv-action-feedback'),
            confirmed ? (action === 'stop' ? tr('Service stopped') : action === 'restart' ? tr('Service restarted') : tr('Service started')) :
            tr('Service state not confirmed. Check logs.'), confirmed ? 'success' : 'error');
    }
}

async function updateControlButtons() {
	window.clearTimeout(controlTimer);
	var status = document.getElementById('sbtv-control-status');
	if (!status || controlBusy) return;
	if (document.body && document.body.classList.contains('modal-overlay-active')) {
		controlTimer = window.setTimeout(updateControlButtons, 5000);
		return;
	}
    var request = ++controlRequest;
    await checkLiveDependencies();
    if (controlBusy || request !== controlRequest || !status.isConnected) return;
    if (!sbtvCoreReady) {
        refreshEnableButton();
        status.textContent = tr('Required packages are missing');
        controlTimer = window.setTimeout(updateControlButtons, 5000);
        return;
    }
	var running = null;
	try {
		var result = await fs.exec('/etc/init.d/sponsorblocktv', [ 'running' ]);
		if (result.code === 0 || result.code === 1) running = result.code === 0;
	} catch (_) {}
	if (controlBusy || request !== controlRequest || !status.isConnected) return;
    refreshEnableButton();
	var devices = uci.sections('sponsorblocktv', 'device') || [];
	var hasDevices = devices.some(function(device) { return !!(device.screen_id || '').trim(); });
	var warning = document.getElementById('sbtv-control-warning');
	if (warning) {
		warning.hidden = hasDevices;
		warning.textContent = hasDevices ? '' : tr('Add a TV before starting the service.');
	}
	status.textContent = !hasDevices ? tr('Waiting for TV configuration') : running === null ? tr('Service status unavailable') : running ? tr('Running') : tr('Stopped');
	['start', 'stop', 'restart'].forEach(function(action) {
		var button = document.getElementById('sbtv-control-' + action);
		if (!button) return;
		var enabled = running !== null && sbtvCoreReady && (action === 'stop' ? running : hasDevices && (action === 'start' ? !running : running));
		button.disabled = !enabled;
		button.style.opacity = enabled ? '1' : '0.45';
	});
	controlTimer = window.setTimeout(updateControlButtons, 5000);
	return running;
}

var pairingBusy = false, manualBusy = false, discoveryBusy = false, scanActive = false;
function deviceActionBusy() { return pairingBusy || manualBusy || discoveryBusy || scanActive; }
function lockDeviceModal(locked) {
    ['sbtv-add-method', 'sbtv-pair-submit', 'sbtv-manual-submit', 'sbtv-close-device', 'sbtv-scan-button', 'sbtv-pair-code', 'sbtv-manual-screen', 'sbtv-manual-name', 'sbtv-manual-offset'].forEach(function(id) {
        var el = document.getElementById(id);
        if (el) el.disabled = id==='sbtv-close-device' ? (pairingBusy || manualBusy || discoveryBusy) : locked;
    });
}
// Validate only the active method, after blur or a submission attempt.
// Keep LuCI's native validation and parse rules, but defer visual errors
// until blur or save. These per-option wrappers are copied into native modals.
function deferNativeValidation(option) {
    if(typeof option.renderWidget!=='function' || typeof option.parse!=='function')return;
    var render=option.renderWidget, parse=option.parse;
    option.renderWidget=function(sectionId,index,value){
        var self=this;
        return Promise.resolve(render.call(self,sectionId,index,value)).then(function(node){
            if(!node || !node.querySelectorAll)return node;
            var fields=node.matches('input.cbi-input-text,input.cbi-input-password,textarea')?[node]:
                Array.from(node.querySelectorAll('input.cbi-input-text,input.cbi-input-password,textarea'));
            // Preserve the original LuCI widget and its bound class instance.
            // Place the message outside password control groups.
            var container=node;
            if(fields.indexOf(node)>=0){
                container=document.createElement('div');
                container.appendChild(node);
            }
            fields.forEach(function(field){
                var required=self.rmempty===false && !self.optional;
                field.setAttribute('data-sbtv-native-validation','true');
                if(required)field.setAttribute('aria-required','true');
                field._sbtvNativeTouched=false;
                var hint=document.createElement('div');
                hint.className='sbtv-field-error';
                hint.setAttribute('data-sbtv-native-error','true');
                hint.setAttribute('aria-live','polite');
                hint.hidden=true;
                if(field.id){
                    hint.id=field.id+'-sbtv-error';
                    var described=field.getAttribute('aria-describedby');
                    field.setAttribute('aria-describedby',(described?described+' ':'')+hint.id);
                }
                container.appendChild(hint);
                function showError(message){
                    hint.textContent=message||'';
                    hint.hidden=!message;
                    if(message)field.setAttribute('aria-invalid','true');
                    else field.removeAttribute('aria-invalid');
                }
                function updateError(ev){
                    if(!field._sbtvNativeTouched){
                        field.classList.remove('cbi-input-invalid');
                        if(field.getAttribute('data-tooltip-style')==='error'){
                            field.removeAttribute('data-tooltip');
                            field.removeAttribute('data-tooltip-style');
                        }
                        showError('');
                        return;
                    }
                    if(ev && ev.type==='validation-success'){
                        showError('');
                        return;
                    }
                    if(!field.classList.contains('cbi-input-invalid')){
                        showError('');
                        return;
                    }
                    var message=required && !String(field.value||'').trim()
                        ?tr('This field is required.')
                        :((ev && ev.detail && ev.detail.message)||field.getAttribute('data-tooltip')||tr('Invalid value.'));
                    showError(message);
                }
                field.addEventListener('validation-failure',updateError);
                field.addEventListener('validation-success',updateError);
                field.addEventListener('blur',function(){field._sbtvNativeTouched=true;},true);
                field.addEventListener('input',function(){
                    if(field._sbtvNativeTouched)self.triggerValidation(sectionId);
                });
                updateError();
            });
            return container;
        });
    };
    option.parse=function(sectionId){
        if(this.isActive(sectionId)){
            var root=this.map.findElement('data-field',this.cbid(sectionId));
            if(root)root.querySelectorAll('[data-sbtv-native-validation]').forEach(function(field){
                field._sbtvNativeTouched=true;
            });
            this.triggerValidation(sectionId);
        }
        return parse.call(this,sectionId);
    };
}
function deferSectionValidation(section){
    (section.children||[]).forEach(function(option){
        if(typeof form.Value==='function' && option instanceof form.Value &&
           !option.keylist && !option.choices)deferNativeValidation(option);
    });
    // Native grid dialogs retain their normal Save/Cancel behavior.
    if(typeof section.handleModalSave==='function' && typeof section.getActiveModalMap==='function'){
        var save=section.handleModalSave;
        section.handleModalSave=function(){
            var root=this.getActiveModalMap();
            if(root){
                var fields=Array.from(root.querySelectorAll('[data-sbtv-native-validation]'));
                fields.forEach(function(field){
                    field._sbtvNativeTouched=true;
                    field.dispatchEvent(new Event('blur'));
                });
                var invalid=fields.find(function(field){return !field.disabled && field.classList.contains('cbi-input-invalid');});
                if(invalid && invalid.focus)invalid.focus();
            }
            return save.apply(this,arguments);
        };
    }
}
function fieldError(field,message) {
    if(!field)return;
    var id=field.id || (field.attrs && field.attrs.id);
    var hint=id && document.getElementById(id+'-error');
    if(message)field.setAttribute('aria-invalid','true');
    else field.removeAttribute('aria-invalid');
    if(hint){hint.textContent=message||'';hint.hidden=!message;}
}
// New whitelist entries are local drafts until Save. Avoid allocating a
// temporary UCI section or constructing/loading a native Map on every Add.
async function refreshGrid(section,parent){
    var previous=document.getElementById('cbi-'+parent.config+'-'+section.sectiontype);
    if(!previous || typeof section.render!=='function')return;
    await section.load();
    var next=await section.render();
    if(previous.isConnected)previous.replaceWith(next);
}
function openWhitelistDraft(section, parent, nameOption, idOption) {
    if(parent.readonly || section._sbtvWhitelistSaving)return;
    var busy=false, failed=false, closed=false;
    function close(){
        if(busy || closed)return;
        closed=true;
        ui.hideModal();
    }
    function validate(field,option,force){
        if(force)field._sbtvTouched=true;
        var value=String(field.value||'').trim();
        var result=option.validate(null,value);
        var message=result===true?'':result;
        if(field._sbtvTouched)fieldError(field,message);
        return message;
    }
    function input(id,label,option){
        var field=E('input',{'id':id,'class':'cbi-input-text','type':'text',
            'aria-required':'true','aria-describedby':id+'-error',
            'blur':function(ev){validate(ev.target,option,true);},
            'input':function(ev){validate(ev.target,option,false);}});
        return {field:field,node:E('div',{'class':'cbi-value'},[
            E('label',{'class':'cbi-value-title','for':id},[label]),
            E('div',{'class':'cbi-value-field'},[field,fieldErrorHint(id)])
        ])};
    }
    var name=input('sbtv-whitelist-name',tr('Channel name'),nameOption);
    var id=input('sbtv-whitelist-id',tr('Channel ID'),idOption);
    var status=E('div',{'role':'status','aria-live':'polite','style':'display:none;overflow-wrap:anywhere'});
    var dismiss=E('button',{'type':'button','class':'btn cbi-button','click':close},[tr('Dismiss')]);
    var submit=E('button',{'type':'button','class':'btn cbi-button cbi-button-positive important','click':function(){
        if(busy || failed || closed || parent.readonly)return;
        var errors=[validate(name.field,nameOption,true),validate(id.field,idOption,true)];
        if(errors.some(Boolean)){
            var first=errors[0]?name.field:id.field;
            if(first.focus)first.focus();
            return;
        }
        var data=parent.data||uci, sid;
        busy=section._sbtvWhitelistSaving=true;
        dismiss.disabled=name.field.disabled=id.field.disabled=true;
        buttonBusy(submit,true,tr('Saving...'));
        actionFeedback(status,tr('Saving...'),'busy');
        return Promise.resolve().then(function(){
            sid=data.add('sponsorblocktv','whitelist');
            data.set('sponsorblocktv',sid,'name',String(name.field.value).trim());
            data.set('sponsorblocktv',sid,'id',String(id.field.value).trim());
            return data.save();
        }).then(function(){
            return refreshGrid(section,parent);
        }).then(function(){
            busy=false;close();
        }).catch(function(){
            // A transport failure may have occurred after UCI accepted the row.
            // Do not automatically retry or delete a possibly saved entry.
            failed=true;
            actionFeedback(status,tr('Unable to confirm channel save. Reload the page before retrying.'),'error');
        }).finally(function(){
            busy=section._sbtvWhitelistSaving=false;
            dismiss.disabled=false;
            name.field.disabled=id.field.disabled=failed;
            buttonBusy(submit,false,tr('Save'));
            submit.disabled=failed;
        });
    }},[tr('Save')]);
    ui.showModal(tr('Whitelisted channel'),[
        E('div',{'class':'sbtv-whitelist-modal sbtv-add-modal'},[name.node,id.node,status]),
        E('div',{'class':'button-row sbtv-modal-footer sbtv-add-footer'},[dismiss,' ',submit])
    ]);
}
function validateDeviceField(field,kind,force) {
    var value=String(field.value||'').trim(), message='';
    if(kind==='code'){
        if(!value)message=tr('This field is required.');
        else if(!/^\d{12}$/.test(value.replace(/\s/g,'')))message=tr('Enter all 12 digits.');
    }else if(kind==='screen'){
        if(!value)message=tr('This field is required.');
        else if(!/^[A-Za-z0-9_-]{8,128}$/.test(value) || (uci.sections('sponsorblocktv','device')||[]).some(function(d){return d.screen_id===value;}))
            message=tr('Invalid or duplicate Screen ID.');
    }else if(kind==='offset'){
        if(value && (!/^-?\d+$/.test(value)||Number(value)<-10000||Number(value)>10000))
            message=tr('Enter an offset from -10000 to 10000 ms.');
    }else if(kind==='name'){
        if(value.length>200 || /[\x00-\x1f\x7f]/.test(value))message=tr('Use up to 200 characters, without control characters.');
    }
    if(force)field._sbtvTouched=true;
    if(field._sbtvTouched)fieldError(field,message);
    return message;
}
function fieldErrorHint(id) {
    return E('div',{id:id+'-error','class':'sbtv-field-error','aria-live':'polite',hidden:true});
}
function setPairMethod(method, animate) {
    var manual = method === 'manual';
    ['sbtv-pair-code','sbtv-manual-screen','sbtv-manual-name','sbtv-manual-offset'].forEach(function(id){
        var f=document.getElementById(id);
        if(f){f._sbtvTouched=false;fieldError(f,'');}
    });
    var select = document.getElementById('sbtv-add-method');
    if (select) select.value = manual ? 'manual' : 'pair';
    ['fields', 'submit', 'instructions'].forEach(function(part) {
        document.getElementById('sbtv-pair-' + part).style.display = manual || part === 'submit' ? 'none' : '';
        document.getElementById('sbtv-manual-' + part).style.display = manual ? '' : 'none';
    });
    if(!manual){
        var code=document.querySelector('#sbtv-pair-code');
        if(code)code.value='';
        var hint=document.getElementById('sbtv-pair-progress');
        if(hint){hint.textContent='';hint.style.display='none';}
    }
    var status = document.getElementById('sbtv-pair-status');
    clearFeedback(status);
    var fields = document.getElementById('sbtv-manual-fields');
    if (manual && animate && fields.animate && !(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches))
        fields.animate([{ opacity: 0, transform: 'translateX(18px)' }, { opacity: 1, transform: 'translateX(0)' }], { duration: 220, easing: 'ease-out' });
}
function uniqueDeviceName(name,screenId) {
    var base=String(name||'').trim()||'YouTube on TV';
    var used=new Set((uci.sections('sponsorblocktv','device')||[]).filter(function(d){
        return d.screen_id && d.screen_id!==screenId;
    }).map(function(d){return (String(d.name||'').trim()||'YouTube on TV').toLowerCase();}));
    if(!used.has(base.toLowerCase()))return base;
    for(var i=2;i<=65;i++){
        var suffix=' #'+i,candidate=base.slice(0,200-suffix.length)+suffix;
        if(!used.has(candidate.toLowerCase()))return candidate;
    }
    return base;
}
function pairErrorMessage(detail) {
    var message=String(detail||'');
    // Core can report a combined failure; do not claim the code expired.
    if(/invalid code, or the TV did not respond/i.test(message))
        return tr('Invalid TV code or TV not responding.');
    if(/invalid pairing code|expected a 12-digit TV code/i.test(message))
        return tr('Invalid TV code.');
    if(/timeout|timed out|deadline exceeded/i.test(message))
        return tr('Request timed out. Try again.');
    if(/network|connection refused|could not resolve|dns|tls|ssl/i.test(message))
        return tr('Connection failed. Try again.');
    return tr('Pairing failed. Try again.');
}
var refreshTVsAfterAdd=null;
async function saveTV(id,name,offset){
    var devices=uci.sections('sponsorblocktv','device')||[];
    if(devices.some(function(d){return d.screen_id===id;}))throw new Error(tr('Invalid or duplicate Screen ID.'));
    if(devices.filter(function(d){return String(d.screen_id||'').trim();}).length>=64)throw new Error(tr('Maximum 64 configured TVs'));
    var sid=uci.add('sponsorblocktv','device');
    uci.set('sponsorblocktv',sid,'screen_id',id);
    uci.set('sponsorblocktv',sid,'name',uniqueDeviceName(name,id));
    uci.set('sponsorblocktv',sid,'offset',offset||'0');
    var initialPolicy={skip_ads:'1',mute_ads:'1',auto_play:'1',skip_sponsorblock:'1',statistics:'0',skip_categories:CATEGORIES.map(function(c){return c[0];}).join(','),minimum_skip_length:'1',controller_mode:'cooperative'};
    Object.keys(initialPolicy).forEach(function(k){uci.set('sponsorblocktv',sid,k,initialPolicy[k]);});
    await uci.save();
    await uci.apply();
}
async function refreshAddedTV(external,status){
    try{
        if(external){
            // LuCI's callLoad reads without clearing staged edits (unload would).
            var values=uci.state && uci.state.values && uci.state.values.sponsorblocktv;
            if(typeof uci.callLoad!=='function' || !values)throw new Error('UCI refresh unavailable');
            var fresh=await uci.callLoad('sponsorblocktv');
            if(!fresh || typeof fresh!=='object')throw new Error('Invalid UCI response');
            Object.keys(fresh).forEach(function(key){
                var row=fresh[key];
                if(row && row['.type']==='device' && !Object.prototype.hasOwnProperty.call(values,key))
                    values[key]=row;
            });
        }
        if(refreshTVsAfterAdd)await refreshTVsAfterAdd();
    }catch(e){
        actionFeedback(status,tr('TV added. Refresh the list.'),'success',true);
        return false;
    }
    return true;
}
function handlePair(ev) {
	if (deviceActionBusy()) return;
	if (!sbtvCoreReady) return checkCoreDeps();
	var codeField = document.querySelector('#sbtv-pair-code');
	var code = { value: (codeField.value || '').replace(/\D/g, '') };
	var status = document.querySelector('#sbtv-pair-status');
	if (!/^\d{12}$/.test(code.value)) {
        validateDeviceField(codeField,'code',true);
        clearFeedback(status);
        if (codeField.focus) codeField.focus();
		return;
	}
	pairingBusy = true;
    lockDeviceModal(true);
	var submit = document.getElementById('sbtv-pair-submit');
	if(submit)submit.style.display='none';
	buttonBusy(submit, true, tr('Pairing...'));

	actionFeedback(status, tr('Pairing...'), 'busy');

	return fs.exec('/usr/sbin/sponsorblocktv-pair', [
		'--list', '--code', code.value.trim()
	]).then(function(res) {
		if (res.code !== 0)
			throw new Error(pairErrorMessage(res.stderr || res.stdout));

        var result;
        try { result = JSON.parse(res.stdout || '{}'); } catch (e) { throw new Error(tr('Invalid pairing response')); }
        if (!result || !/^[A-Za-z0-9_-]{8,128}$/.test(result.screen_id || ''))
            throw new Error(tr('No valid Screen ID returned.'));
        codeField.value = '';
        var hint=document.getElementById('sbtv-pair-progress');if(hint){hint.textContent='';hint.style.display='none';}
        actionFeedback(status,tr('Saving TV configuration...'),'busy');
        return saveTV(result.screen_id,result.name,'0').then(async function(){
            actionFeedback(status,tr('TV added successfully.'),'success',true);
            await refreshAddedTV(false,status);
        }).catch(function(err){
            setPairMethod('manual',false);
            document.getElementById('sbtv-manual-screen').value=result.screen_id;
            document.getElementById('sbtv-manual-name').value=uniqueDeviceName(result.name,result.screen_id);
            document.getElementById('sbtv-manual-offset').value='0';
            actionFeedback(status,err.message||tr('Unable to save TV'),'error');
        });
	}).catch(function(err) {
		status.replaceChildren(E('span', { 'style': 'font-weight:600;margin-right:6px', 'aria-hidden': 'true' }, [ '⚠' ]), E('span', {}, [ err.message && err.message.length <= 60 ? err.message : tr('Pairing failed. Try again.') ]));
		status.style.display = 'block';
		status.style.color = '#d32f2f';
        status.setAttribute('aria-busy', 'false');
        if(submit)submit.style.display='';
	}).finally(function() {
		pairingBusy = false;
        lockDeviceModal(false);
		buttonBusy(submit, false, tr('Pair TV'));
	});
}

return view.extend({
	load: async function() {
        await loadAppLanguage();
		return uci.load('sponsorblocktv').then(function() { return true; }).catch(function(err) {
			return execOutput('/usr/sbin/sponsorblocktv-deps', []).then(function(output) {
				if (/^MISSING sponsorblocktv$/m.test(output)) return false;
				throw err;
			});
		});
	},

	handleSave: function() {
		if (!sbtvCoreReady) return checkCoreDeps();
		return this.super('handleSave', arguments);
	},
	handleSaveApply: function() {
		if (!sbtvCoreReady) return checkCoreDeps();
		return this.super('handleSaveApply', arguments);
	},
	render: function(configLoaded) {
		var m, s, o;
		if (configLoaded === false) {
			var placeholder = E('p', {}, [ tr('Install the required packages first.') ]);
			afterInstall = async () => {
				await uci.load('sponsorblocktv');
				placeholder.replaceWith(await this.render(true));
			};
			window.requestAnimationFrame(checkCoreDeps);
			return placeholder;
		}

		m = new form.Map('sponsorblocktv', tr('SponsorBlockTV'),
			tr('SponsorBlockTV for YouTube TV and Cast.'));

		s = m.section(form.GridSection, 'device', tr('TVs'),
			tr('Manage paired TVs and Cast receivers.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.modaltitle = tr('TV');
		s.nodescriptions = true;
		s.handleAdd = function() {
            if (pairingBusy || manualBusy || discoveryBusy) return;
			ui.showModal(tr('Add TV'), [
				E('div', { 'class':'sbtv-enter sbtv-add-modal','style': 'overflow-anchor:none' }, [ discoverBox, pairBox ]),
				E('div', { 'class': 'button-row sbtv-modal-footer' }, [
					E('button', { 'type': 'button', 'id': 'sbtv-close-device', 'class': 'btn', 'click': function() { if (!pairingBusy && !manualBusy && !discoveryBusy) ui.hideModal(); } }, [ tr('Close') ])
				])
			]);
            if(scanActive){
                lockDeviceModal(true);
                return;
            }
            setPairMethod('pair',false);
            ['sbtv-manual-screen','sbtv-manual-name','sbtv-manual-offset'].forEach(function(id){
                var f=document.getElementById(id);if(f)f.value=id==='sbtv-manual-offset'?'0':'';
            });
            document.getElementById('sbtv-discover-results').replaceChildren();
            var status=document.getElementById('sbtv-scan-status');
            status.textContent='';status.style.color='';
            scanButton.textContent=tr('Scan for TVs');
		};

		var deviceSection = s;
		o = s.option(form.Value, 'name', tr('TV name'));
		o.placeholder = 'YouTube on TV';

		o = s.option(form.Value, 'screen_id', tr('Screen ID'),
			tr('Filled automatically when pairing.'));
		o.rmempty = false;
        o.validate = function(section, value) {
            if (!String(value||'').trim())return tr('This field is required.');
            if (!/^[A-Za-z0-9_-]{8,128}$/.test(value))
                return tr('Enter a valid Screen ID (8-128 letters, numbers, _ or -)');
            var duplicate = (uci.sections('sponsorblocktv', 'device') || []).some(function(d) {
                return d['.name'] !== section && d.screen_id === value;
            });
            return duplicate ? tr('This Screen ID is already added') : true;
        };

		o = s.option(form.Value, 'offset', tr('Offset (ms)'),
			tr('Positive: seek earlier. Negative: seek later.'));
		o.datatype = 'range(-10000,10000)';
		o.placeholder = '0';

        deferSectionValidation(deviceSection);
		s = m.section(form.TypedSection, 'sponsorblocktv', tr('Settings'));
		s.anonymous = true;
        s.tab('general',tr('General'));
        s.tab('advanced',tr('Advanced'));


        o = s.taboption('advanced', form.Flag, 'debug', tr('Debug logging'),
			tr('Enable detailed logs.'));
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'http_tracing', tr('HTTP tracing'),
			tr('Log HTTP method, status and latency. No credentials or bodies.'));
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'data_dir', tr('Data directory'),
			tr('Config and data storage directory.'));
		o.datatype = 'directory';
		o.placeholder = '/etc/sponsorblocktv/data';

		o = s.taboption('general', form.Value, 'join_name', tr('Controller name'),
			tr('Name visible to other YouTube clients.'));
		o.placeholder = 'SponsorBlockTV';
		o.validate = function(section, value) { return !value || (value.length <= 200 && !/[\x00-\x1f\x7f]/.test(value)) ? true : tr('Use up to 200 characters, without control characters.'); };

		o = s.taboption('general', form.Value, 'apikey', tr('YouTube API key'),
			tr('Optional YouTube Data API key for Whitelist channel lookup. When empty, public video metadata is used.'));
		o.password = true;
		o.validate = function(section, value) { return !value || (value.length <= 512 && !/[\x00-\x1f\x7f]/.test(value)) ? true : tr('Invalid YouTube API key'); };

		o = s.taboption('general', form.Flag, 'skip_count_tracking', tr('Report skipped segments'),
			tr('Report skipped segments to the SponsorBlock API.'));
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'use_proxy', tr('Use system proxy'),
			tr('Compatibility only; connections are direct.'));
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'sponsorblock_api_url', tr('SponsorBlock API URL'));
		o.validate = function(section, value) {
			if (!value) return true;
			try { var raw = value.trim(); var u = new URL(raw); if (raw.length <= 2048 && /^https?:\/\/(?:\[[0-9a-fA-F:.]+\]|[A-Za-z0-9._-]+)(?::[0-9]{1,5})?(?:\/[^?#\s\\]*)?$/.test(raw) && !/[\x00-\x1f\x7f]/.test(raw) && u.port !== '0' && !u.search && !u.hash && !u.username && !u.password) return true; } catch (_) {}
			return tr('Enter an HTTP or HTTPS base URL without credentials, query or fragment');
		};
		o.placeholder = 'https://sponsor.ajay.app/api/';

        deferSectionValidation(s);
		s = m.section(form.GridSection, 'whitelist', tr('Channel whitelist'),
			tr('Exclude channels from automatic segment skipping. If lookup fails, skip is paused for that video.'));
		s.addremove = true;
		s.anonymous = true;
		s.modaltitle = tr('Whitelisted channel');
		s.nodescriptions = true;
		o = s.option(form.Value, 'name', tr('Channel name'));
        o.rmempty=false;
        o.validate=function(section,value){return String(value||'').trim()?true:tr('This field is required.');};
        var whitelistNameOption=o;
		o = s.option(form.Value, 'id', tr('Channel ID'));
		o.datatype = 'string';
        o.rmempty = false;
        o.validate = function(section, value) {
            if (!String(value||'').trim())return tr('This field is required.');
            if (!/^UC[A-Za-z0-9_-]{22}$/.test(value || ''))
                return tr('Enter a Channel ID (UC + 22 characters).');
            var duplicate = (uci.sections('sponsorblocktv', 'whitelist') || []).some(function(ch) {
                return ch['.name'] !== section && ch.id === value;
            });
            return duplicate ? tr('This channel is already added') : true;
        };

        var whitelistIdOption=o;
        deferSectionValidation(s);
        s.handleAdd=function(){return openWhitelistDraft(this,m,whitelistNameOption,whitelistIdOption);};
		var scanButton, scanBusy = false;
		var discoverBox = E('section', { 'class': 'cbi-section sbtv-panel', 'aria-labelledby':'sbtv-discover-title' }, [
			E('h3', {'class':'sbtv-panel-title','id':'sbtv-discover-title'}, [ tr('Discover TVs on local network') ]),
			E('p', { 'class': 'cbi-section-descr' }, [ tr('Find TVs on LAN.') ]),
			E('style', {}, [ '@keyframes sbtv-add-spin { to { transform:rotate(360deg); } }' ]),
			scanButton = E('button', { 'id': 'sbtv-scan-button', 'type': 'button', 'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					if (ev) { ev.preventDefault(); ev.stopPropagation(); }
					if (deviceActionBusy() || scanBusy || scanButton.disabled) return;
					scanBusy = scanActive = true;
                    lockDeviceModal(true);
                    scanButton.disabled = false;
					scanButton.setAttribute('aria-disabled', 'true');
                    scanButton.setAttribute('aria-busy', 'true');
					scanButton.textContent = tr('Scanning...');
					var output = document.getElementById('sbtv-discover-results');
					var scanStatus = document.getElementById('sbtv-scan-status');
					scanStatus.style.color = '';
					scanStatus.replaceChildren(E('span', { 'aria-hidden': 'true', 'style': 'display:inline-block;width:14px;height:14px;border:2px solid #aaa;border-top-color:#1676c2;border-radius:50%;animation:sbtv-add-spin .8s linear infinite;vertical-align:middle;margin-right:8px' }), E('span', {}, [ tr('Scanning local network...') ]));
					output.inert = false;
					output.style.opacity = '';
                    output.replaceChildren();
                    var scanId = Array.from({length:32},function(){return Math.floor(Math.random()*16).toString(16);}).join('');
                    var polling = true, pollTimer, adding = false;
                    var readyRows = new Map(), candidateRows = new Map(), renderedKey = null;
                    function canConnect(d) { return d.source==='Cast' && d.port===8009 && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(d.id||'') && /^\d{1,3}(\.\d{1,3}){3}$/.test(d.host||''); }
                    function syncLocks() {
                        lockDeviceModal(scanActive || discoveryBusy);
                        // A running scan has an aria-disabled scan button, but
                        // its verified device rows remain actionable.
                        scanButton.disabled = discoveryBusy;
                        readyRows.forEach(function(row) {
                            row._addButton.disabled = adding || !!row._added;
                        });
                        candidateRows.forEach(function(row) { row._addButton.disabled = scanActive || adding || !!row._added; });
                    }
                    function discoveryInfo(device, ready) {
                        var rows = [E('strong',{},[String(device.name || 'TV')])];
                        var hardware = [device.manufacturer,device.model].filter(Boolean);
                        if (hardware.length === 2 && String(hardware[1]).toLowerCase().startsWith(String(hardware[0]).toLowerCase()))
                            hardware.shift();
                        hardware = hardware.filter(function(value){return String(value).trim() !== String(device.name || 'TV').trim();});
                        var identity = hardware.filter(Boolean).join(' \u00b7 ');
                        if(identity) rows.push(E('span',{'class':'sbtv-discover-detail'},[identity]));
                        var protocol = device.source || device.type || 'LAN';
                        var connection = [device.application,protocol].filter(Boolean).join(' \u00b7 ');
                        if(!ready) connection += ' \u00b7 '+(canConnect(device)?tr('YouTube may open when adding this TV.'):tr('Pair using the TV code below.'));
                        rows.push(E('span',{'class':'sbtv-discover-detail'},[connection]));
                        var details = [];
                        function detail(label, value) {
                            if (value != null && String(value).trim())
                                details.push(E('div', {'class':'sbtv-discover-detail'}, [label+': '+String(value)]));
                        }
                        detail(tr('Manufacturer'), device.manufacturer);
                        detail(tr('Model'), device.model);
                        detail(tr('IP address'), device.host);
                        detail(tr('Port'), device.port);
                        detail(tr('Application'), device.application);
                        detail(tr('Protocol'), protocol);
                        var states = {running:tr('Running'),stopped:tr('Stopped'),hidden:tr('Hidden')};
                        if (Object.prototype.hasOwnProperty.call(states,device.app_state))
                            detail(tr('Application status'),states[device.app_state]);
                        detail('UUID', device.uuid);
                        if(details.length>1)
                            rows.push(E('details',{'class':'sbtv-discover-more'},[
                                E('summary',{},[tr('Details')]),
                                E('div',{'class':'sbtv-discover-more-content'},details)
                            ]));
                        return rows;
                    }
                        function createReadyRow(device, connect) {
							var status = E('div', { 'class': 'cbi-section-descr', 'role': 'status', 'aria-live': 'polite', 'style': 'display:none;width:100%;margin:0;line-height:1.5;overflow-wrap:anywhere' });
							var button = E('button', { 'type': 'button', 'class': 'btn cbi-button cbi-button-apply',
								'click': function() {
									if (pairingBusy || manualBusy || discoveryBusy || adding || button.disabled) return;
									adding = discoveryBusy = true;
                                    syncLocks();
									button.disabled = true;
									button.textContent = tr('Adding TV...');
                                    button.setAttribute('aria-busy', 'true');
									status.style.color = '';
                                    status.style.display = 'block';
									status.replaceChildren(E('span', { 'aria-hidden': 'true', 'style': 'display:inline-block;width:14px;height:14px;border:2px solid #aaa;border-top-color:#1676c2;border-radius:50%;animation:sbtv-add-spin .8s linear infinite;vertical-align:middle;margin-right:8px' }), E('span', {}, [ tr('Adding TV, please wait...') ]), E('progress', { 'aria-label': tr('Adding TV...'), 'style': 'display:block;width:100%;max-width:320px;height:5px;margin-top:8px' }));
									scanButton.disabled = true;
									return Promise.resolve().then(function() {
										return fs.exec('/usr/sbin/sponsorblocktv-discover', [ '--add', connect?'cast:'+device.id:device.screen_id, '--scan', scanId ]);
									}).then(function(result) {
										var response;
										try { response = JSON.parse(result.stdout || '{}'); } catch (e) { response = {}; }
										if (result.code !== 0 || response.added !== true)
											throw new Error(response.error || result.stderr || tr('Add failed'));
										row._added = true;
                                        button.textContent = tr('Added');
										actionFeedback(status, tr('TV added successfully.'), 'success', true);
                                        return refreshAddedTV(true,status);
									}).catch(function(err) {
										button.disabled = false;
										button.textContent = tr('Retry add TV');
										status.style.color = '#b42318';
										status.replaceChildren(E('strong', {}, [ tr('Add failed: ') + err.message + (connect?' '+tr('Pair using the TV code below.'):'') ]));
									}).finally(function() {
										button.removeAttribute('aria-busy');
                                        adding = discoveryBusy = false;
                                        syncLocks();
									});
								}
							}, [ tr('Add TV') ]);
							var row = E('div', { 'class': 'sbtv-discover-device', 'data-ready': connect?'false':'true', 'data-connect': connect?'true':'false' }, [
								E('div', {'class':'sbtv-discover-info'}, discoveryInfo(device,!connect)),
								button, status
							]);
                            row._info = row.children[0];
                            row._metadataKey = JSON.stringify(device);
                            row._addButton = button;
                            return row;
                        }

                    function renderResults(data) {
                        var devices = Array.isArray(data.devices) ? data.devices : [];
                        var unpaired = Array.isArray(data.unpaired) ? data.unpaired : [];
                        var key = JSON.stringify([devices, unpaired]);
                        if (key === renderedKey) return;
                        renderedKey = key;
                        var rows = [];
                        devices.forEach(function(device) {
                            if (!/^[A-Za-z0-9_-]{8,128}$/.test(device.screen_id || '')) return;
                            if (!readyRows.has(device.screen_id))
                                readyRows.set(device.screen_id, createReadyRow(device));
                            else {
                                var row = readyRows.get(device.screen_id), metadataKey = JSON.stringify(device);
                                if (row._metadataKey !== metadataKey) {
                                    row._metadataKey = metadataKey;
                                    var previous = Array.from(row._info.children).find(function(el){return el.tagName === 'DETAILS' || el.tag === 'details';});
                                    var next = discoveryInfo(device,true);
                                    var disclosure = next.find(function(el){return el.tagName === 'DETAILS' || el.tag === 'details';});
                                    if(previous && disclosure && previous.open) disclosure.open = true;
                                    row._info.replaceChildren.apply(row._info, next);
                                }
                            }
                        });
                        // Snapshots are cumulative. Keep the same row/button
                        // objects during polling and final scan completion.
                        readyRows.forEach(function(row) { rows.push(row); });
                        unpaired.forEach(function(device) {
                            if(canConnect(device)) {
                                if(!candidateRows.has(device.id))candidateRows.set(device.id,createReadyRow(device,true));
                                rows.push(candidateRows.get(device.id));return;
                            }
                            rows.push(E('div', {'class':'sbtv-discover-device sbtv-discover-code-notice','data-ready':'false'}, [
                                E('div',{'class':'sbtv-discover-info'},discoveryInfo(device,false))
                            ]));
                        });
                        output.replaceChildren.apply(output, rows);
                        syncLocks();
                    }
                    function readProgress() {
                        if (!polling) return;
                            if(!output.isConnected){pollTimer=window.setTimeout(readProgress,900);return;}
                        fs.exec('/usr/sbin/sponsorblocktv-discover',['--status',scanId]).then(function(res) {
                            if(!polling || res.code!==0) return;
                            var d=JSON.parse(res.stdout||'{}');
                            if(d.scan_id!==scanId || d.error || !Array.isArray(d.devices)) return;
                            renderResults(d);
                            scanStatus.textContent=tr('Scanning local network...')+' ('+(d.devices.length+(Array.isArray(d.unpaired)?d.unpaired.length:0))+')';
                        }).catch(function(){}).finally(function(){if(polling)pollTimer=window.setTimeout(readProgress,900);});
                    }
                    var scanRequest=fs.exec('/usr/sbin/sponsorblocktv-discover',['--scan',scanId]);
                    pollTimer=window.setTimeout(readProgress,400);
                    return scanRequest.then(function(res) {
                        polling=false; window.clearTimeout(pollTimer);
                        var data;
                        try { data = JSON.parse(res.stdout || '{}'); } catch (e) { throw new Error(tr('Invalid discovery response')); }
                        if (res.code !== 0 || data.error) throw new Error(data.error || tr('Discovery failed'));
                        if (!Array.isArray(data.devices) || data.scan_id !== scanId || data.pending) throw new Error(tr('Invalid or incomplete discovery response'));
                        renderResults(data);
                        var unpaired = Array.isArray(data.unpaired) ? data.unpaired : [];
                        if (!data.devices.length && !unpaired.length) {
                            scanStatus.textContent = tr('Scan completed successfully.') + ' '+tr('No compatible TVs found. Check the TV and retry.') + (Array.isArray(data.warnings) && data.warnings.length ? ' \u00b7 '+data.warnings.join('; ') : '');
                            scanButton.textContent = tr('Retry scan');
                            return;
                        }
                        scanStatus.style.color = '';
                        scanStatus.replaceChildren(
                            E('div',{'class':'sbtv-scan-success'},[E('span',{'aria-hidden':'true','class':'sbtv-scan-check'},['\u2713']),E('strong',{},[tr('Scan completed successfully.')])]),
                            E('div',{'class':'sbtv-scan-counts'},[
                                E('span',{},[tr('Ready to add')+': '+(data.devices.length+unpaired.filter(canConnect).length)]),
                                E('span',{},[tr('TV code required')+': '+unpaired.filter(function(d){return !canConnect(d);}).length])
                            ])
                        );
                        if (Array.isArray(data.warnings) && data.warnings.length)
                            scanStatus.appendChild(E('div',{'class':'sbtv-scan-warning'},[data.warnings.join('; ')]));
                        scanButton.textContent = tr('Scan again');
					}).catch(function(err) {
						scanStatus.style.color = '#b42318';
						scanStatus.textContent = tr('Discovery error: ') + err.message;
						scanButton.textContent = tr('Retry scan');
					}).finally(function() {
						polling=false; window.clearTimeout(pollTimer);
                        scanBusy = scanActive = false;
                        syncLocks();
						scanButton.removeAttribute('aria-disabled');
                        scanButton.removeAttribute('aria-busy');
						output.inert = false;
						output.style.opacity = '';
					});
				}
			}, [ tr('Scan for TVs') ]),
			E('div', { 'id': 'sbtv-scan-status', 'role': 'status', 'aria-live': 'polite', 'style': 'display:block;clear:both;margin:12px 0 0;line-height:1.5;overflow-wrap:anywhere' }),
			E('div', { 'id': 'sbtv-discover-results', 'class': 'cbi-section-descr', 'style': 'display:block;clear:both;margin:0' })
		]);

		var pairBox = E('section', { 'class': 'cbi-section sbtv-panel sbtv-pair-panel', 'aria-labelledby':'sbtv-pair-title' }, [
			E('h3', {'class':'sbtv-panel-title','id':'sbtv-pair-title'}, [ tr('New TV') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for':'sbtv-add-method' }, [ tr('Connection method') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('select', { 'id': 'sbtv-add-method', 'class': 'cbi-input-select',
                        'change': function(ev) { setPairMethod(ev.target.value, false); }
					}, [
						E('option', { 'value': 'pair' }, [ tr('Pair with TV code') ]),
						E('option', { 'value': 'manual' }, [ tr('Add using Screen ID') ])
					])
				])
			]),
			E('div', { 'id': 'sbtv-pair-fields' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for':'sbtv-pair-code' }, [ tr('Pairing code') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
                        'id': 'sbtv-pair-code', 'class': 'cbi-input-text', 'type': 'text',
                        'inputmode': 'numeric', 'autocomplete': 'one-time-code',
                        'placeholder': '000 000 000 000', 'aria-label': tr('12-digit TV pairing code'), 'aria-describedby':'sbtv-pair-progress sbtv-pair-code-error', 'aria-required':'true', 'blur':function(ev){validateDeviceField(ev.target,'code',true);},
                        'style': 'width:100%;max-width:100%;box-sizing:border-box;min-height:44px;font-size:16px;text-align:center;letter-spacing:.12em;font-variant-numeric:tabular-nums',
                        'input': function(ev) {
                            var field = ev.target, raw = field.value;
                            var retry=document.getElementById('sbtv-pair-submit');if(retry)retry.style.display='none';
                            var at = field.selectionStart == null ? raw.length : field.selectionStart;
                            var count = raw.slice(0, at).replace(/\D/g, '').length;
                            var digits = raw.replace(/\D/g, '').slice(0, 12);
                            field.value = (digits.match(/.{1,3}/g) || []).join(' ');
                            validateDeviceField(field,'code',false);
                            var pos = Math.min(field.value.length, count + Math.floor(Math.max(0, count - 1) / 3));
                            if (field.setSelectionRange) field.setSelectionRange(pos, pos);
                            var hint=document.getElementById('sbtv-pair-progress');
                            if(hint){var partial=digits.length>0 && digits.length<12;hint.textContent=partial?digits.length+' / 12':'';hint.style.display=partial?'':'none';}
                            if(digits.length===12 && field===document.querySelector('#sbtv-pair-code') && !deviceActionBusy())
                                return handlePair(ev);


                        },
                        'keydown': function(ev) {
                            var f = ev.target, at = f.selectionStart;
                            if(ev.key==='Enter'){
                                if(ev.preventDefault)ev.preventDefault();
                                return handlePair(ev);
                            }

                            if (ev.key === 'Backspace' && at === f.selectionEnd && at > 1 && f.value[at - 1] === ' ' && f.setSelectionRange)
                                f.setSelectionRange(at - 2, at);
                        }
                    }),
                    fieldErrorHint('sbtv-pair-code'),
                    E('div',{'id':'sbtv-pair-progress','class':'cbi-section-descr','aria-live':'polite','style':'display:none;text-align:center;margin-top:6px'},[])
				])
			]),

			]),
			E('div', { 'id': 'sbtv-manual-fields', 'style': 'display:none' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for':'sbtv-manual-screen' }, [ tr('Screen ID') ]),
					E('div', { 'class': 'cbi-value-field' }, [ E('input', {
						'id': 'sbtv-manual-screen', 'class': 'cbi-input-text', 'type': 'text', 'aria-required':'true', 'aria-describedby': 'sbtv-manual-screen-error', 'blur':function(ev){validateDeviceField(ev.target,'screen',true);}, 'input':function(ev){validateDeviceField(ev.target,'screen',false);},
						'placeholder': 'Screen ID'
					}), fieldErrorHint('sbtv-manual-screen') ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for':'sbtv-manual-name' }, [ tr('TV name') ]),
					E('div', { 'class': 'cbi-value-field' }, [ E('input', {
						'id': 'sbtv-manual-name', 'class': 'cbi-input-text', 'type': 'text', 'aria-describedby':'sbtv-manual-name-error', 'blur':function(ev){validateDeviceField(ev.target,'name',true);}, 'input':function(ev){validateDeviceField(ev.target,'name',false);},
						'placeholder': 'YouTube on TV'
					}), fieldErrorHint('sbtv-manual-name') ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for':'sbtv-manual-offset' }, [ tr('Offset (ms)') ]),
					E('div', { 'class': 'cbi-value-field' }, [ E('input', {
						'id': 'sbtv-manual-offset', 'class': 'cbi-input-text', 'type': 'number', 'value': '0', 'aria-describedby':'sbtv-manual-offset-error', 'blur':function(ev){validateDeviceField(ev.target,'offset',true);}, 'input':function(ev){validateDeviceField(ev.target,'offset',false);}
					}), fieldErrorHint('sbtv-manual-offset') ])
				])
			]),
			E('div', { 'class': 'cbi-value sbtv-pair-actions' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'id': 'sbtv-pair-submit', 'type': 'button', 'style':'display:none',
						'class': 'btn cbi-button cbi-button-action',
						'click': handlePair
					}, [ tr('Pair TV') ]),
					E('button', {
						'id': 'sbtv-manual-submit', 'style': 'display:none',
						'class': 'btn cbi-button cbi-button-action',
						'type': 'button', 'click': function() {
                            if (deviceActionBusy() || !sbtvCoreReady) return;
							var id = document.getElementById('sbtv-manual-screen').value.trim();
							var name = document.getElementById('sbtv-manual-name').value.trim();
							var offset = document.getElementById('sbtv-manual-offset').value.trim() || '0';
                            var status = document.getElementById('sbtv-pair-status');
                            var screenField = document.getElementById('sbtv-manual-screen');
                            var offsetField = document.getElementById('sbtv-manual-offset');
                            var nameField=document.getElementById('sbtv-manual-name');
                            var errors=[[screenField,'screen'],[offsetField,'offset'],[nameField,'name']].map(function(entry){
                                return {field:entry[0],message:validateDeviceField(entry[0],entry[1],true)};
                            });
                            var first=errors.find(function(entry){return !!entry.message;});
                            if(first){
                                clearFeedback(status);
                                if(first.field.focus)first.field.focus();
                                return;
                            }
                            if ((uci.sections('sponsorblocktv', 'device') || []).filter(function(d) { return String(d.screen_id || '').trim(); }).length >= 64) {
                                actionFeedback(status, tr('Maximum 64 configured TVs'), 'error');
                                return;
                            }
                            manualBusy = true;
                            lockDeviceModal(true);
                            var submit = document.getElementById('sbtv-manual-submit');
                            buttonBusy(submit, true, tr('Adding TV...'));
                            actionFeedback(status, tr('Saving TV configuration...'), 'busy');
                            return saveTV(id,name,offset).then(async function(){
                                    actionFeedback(status,tr('TV added successfully.'),'success',true);
                                    document.getElementById('sbtv-manual-screen').value='';
                                    await refreshAddedTV(false,status);
                                }).catch(function(err) {
                                    actionFeedback(status, err.message || tr('Unable to save TV'), 'error');
                                }).finally(function() {
                                    manualBusy = false;
                                    lockDeviceModal(false);
                                    buttonBusy(submit, false, tr('Add TV'));
                                });
						}
					}, [ tr('Add TV') ]),
					E('div', { 'id': 'sbtv-pair-status', 'role': 'status', 'aria-live': 'polite', 'style': 'display:none;clear:both;width:100%;flex-basis:100%;margin-top:12px;line-height:1.5;overflow-wrap:anywhere' }),
					E('p', { 'id': 'sbtv-pair-instructions', 'class': 'cbi-section-descr', 'style': 'margin-top:16px;margin-bottom:4px;line-height:1.5' },
						[ tr('On TV: YouTube > Settings > Link with TV code. Enter the 12-digit code.') ]),
					E('p', { 'id': 'sbtv-manual-instructions', 'class': 'cbi-section-descr', 'style': 'display:none;margin-top:16px;margin-bottom:4px;line-height:1.5' }, [ tr('Enter the Screen ID of your TV.') ])
				])
			])
		]);

		var controlBox = E('section', { 'class': 'cbi-section sbtv-panel sbtv-service-panel', 'aria-labelledby':'sbtv-service-title' }, [
			E('h3', {'class':'sbtv-panel-title','id':'sbtv-service-title'}, [ tr('Service control') ]),

			E('div', { 'id': 'sbtv-control-status', 'class':'sbtv-service-status','role': 'status', 'aria-live': 'polite', 'style': 'display:block;margin:0 0 14px 0;font-weight:400' }, [ E('style', {}, [ '@keyframes sbtv-status-spin { to { transform:rotate(360deg); } }' ]), E('div', { 'style': 'display:flex;align-items:center;gap:10px;margin-bottom:10px' }, [ E('span', { 'aria-hidden': 'true', 'style': 'display:inline-block;width:16px;height:16px;flex-shrink:0;border:3px solid #aaa;border-top-color:#1676c2;border-radius:50%;animation:sbtv-status-spin .8s linear infinite' }), E('span', {}, [ tr('Checking service status...') ]) ]), E('progress', { 'aria-label': tr('Checking service status'), 'style': 'display:block;width:100%;max-width:420px;height:8px' }) ]),
			E('div', { 'id': 'sbtv-action-feedback', 'role': 'status', 'aria-live': 'polite', 'style': 'min-height:1.5em;overflow-wrap:anywhere;margin-bottom:8px' }),
            E('p', { 'id': 'sbtv-control-warning', 'hidden': true, 'role': 'alert', 'style': 'padding:10px 12px;border-left:4px solid #d89a20;background:rgba(216,154,32,0.12);margin:12px 0' }),
            E('style', {}, [ '@keyframes sbtv-control-pulse { 0%,100% { opacity:0.7; } 50% { opacity:0.4; } }' ]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field sbtv-service-actions', 'style': 'display:flex;flex-wrap:wrap;align-items:center;gap:12px' }, [
                    E('button', {
                        'type': 'button', 'id': 'sbtv-control-enable',
                        'class': 'btn cbi-button cbi-button-action sbtv-control-button',
                        'style': 'opacity:0.45', 'disabled': true,
                        'click': function(ev) {
                            if (controlBusy) return;
                            var section = (uci.sections('sponsorblocktv', 'sponsorblocktv') || [])[0];
                            if (!section) return;
                            var name = section['.name'];
                            var enabled = uci.get('sponsorblocktv', name, 'enabled') === '1';
                            uci.set('sponsorblocktv', name, 'enabled', enabled ? '0' : '1');
                            refreshEnableButton();
                            actionFeedback(document.getElementById('sbtv-action-feedback'), tr('Save & Apply to keep the startup setting.'), 'success', true);
                        }
                    }, [ tr('Enable') ]),

					E('button', {
						'type': 'button', 'style': 'opacity:0.45', 'disabled': true, 'id': 'sbtv-control-restart', 'class': 'btn cbi-button cbi-button-apply sbtv-control-button',
						'click': function() { return serviceAction('restart'); }
					}, [ tr('Restart') ]),
					E('button', {
						'type': 'button', 'style': 'opacity:0.45', 'disabled': true, 'id': 'sbtv-control-stop', 'class': 'btn cbi-button cbi-button-reset sbtv-control-button',
						'click': function() { return serviceAction('stop'); }
					}, [ tr('Stop') ]),
					E('button', {
						'type': 'button', 'style': 'opacity:0.45', 'disabled': true, 'id': 'sbtv-control-start', 'class': 'btn cbi-button cbi-button-action sbtv-control-button',
						'click': function() { return serviceAction('start'); }
					}, [ tr('Start') ])
				])
			])
		]);

		/* The pairing, control, dependency and discovery widgets are not form
		   elements, so they are injected into the map element after each
		   render. Hooking renderContents (rather than chaining off render()
		   only once) keeps them present when LuCI re-renders the map, e.g.
		   when the page footer "Reset" button calls Map.reset(). */
		var livePlayer = createLivePlayer(function() { deviceSection.handleAdd(); });
        refreshTVsAfterAdd=async function(){
            await refreshGrid(deviceSection,m);
            await livePlayer.refresh();
            // Service controls refresh once the modal closes on their next tick.
        };
		var renderContents = m.renderContents.bind(m);
		m.renderContents = function() {
			return renderContents().then(function(mapEl) {
				if (!mapEl || typeof mapEl.insertBefore !== 'function')
					return mapEl;
                mapEl.setAttribute('data-sbtv-page','true');
                var first=mapEl.firstChild;
                // Keep the native LuCI title and description ahead of the dashboard.
                while(first && first.nodeType===1 && (first.tagName==='H2' || (first.classList && first.classList.contains('cbi-map-descr'))))first=first.nextSibling;
                mapEl.insertBefore(livePlayer.panel,first);
                mapEl.insertBefore(controlBox,first);
				return mapEl;
			});
		};

		return m.render().then(function(node) {
			mapNode = node;
			node.inert = true;
			node.style.display = 'none';
			setControlsChecking(true);
			var loading = E('div', { 'role': 'status', 'aria-live': 'polite', 'style': 'padding:40px 18px;max-width:420px;margin:30px auto;text-align:center' }, [
				E('style', {}, [ '@keyframes sbtv-page-spin { to { transform:rotate(360deg); } }' ]),
				E('div', { 'style': 'display:flex;align-items:center;justify-content:center;gap:12px;margin-bottom:18px' }, [
					E('span', { 'aria-hidden': 'true', 'style': 'width:24px;height:24px;border:3px solid #aaa;border-top-color:#1676c2;border-radius:50%;animation:sbtv-page-spin .8s linear infinite' }),
					E('strong', {}, [ tr('Checking service status...') ])
				]),
				E('progress', { 'aria-label': tr('Checking service status'), 'style': 'display:block;width:100%;height:5px;margin:0 auto' })
			]);
			var loadingStyle = E('style', {}, [ 'body:has(#sbtv-page-loading) .cbi-page-actions, body:has(#sbtv-page-loading) .cbi-page-actions-wrapper { display:none !important; }' ]);
			loading.id = 'sbtv-page-loading';
			var feedbackStyle = E('style', {}, ['@keyframes sbtv-action-spin{to{transform:rotate(360deg)}} .sbtv-action-spinner{display:inline-block;width:14px;height:14px;border:2px solid #aaa;border-top-color:#1676c2;border-radius:50%;animation:sbtv-action-spin .8s linear infinite;vertical-align:middle;margin-right:8px} button[aria-busy=true]{cursor:wait} @media(prefers-reduced-motion:reduce){.sbtv-action-spinner{animation:none!important}}']);
            var wrapper = E('div', {'class':'sbtv-page'}, [ E('link',{rel:'stylesheet',href:L.resource('sponsorblocktv/player.css')+'?v=175'}),feedbackStyle, loadingStyle, loading, E('div', { 'id': 'sbtv-dependency-feedback', 'role': 'status', 'aria-live': 'polite', 'style': 'display:none;margin:10px 0;overflow-wrap:anywhere' }), node ]);
			window.requestAnimationFrame(function() {
				Promise.resolve().then(checkCoreDeps).then(updateControlButtons).catch(function(err) {
					actionFeedback(document.getElementById('sbtv-dependency-feedback'), err.message || tr('Unable to check service status'), 'error');
				}).finally(function() {
					loading.remove();
                    wrapper.appendChild(E('footer',{'class':'sbtv-developer-credit'},[ tr('Author')+': '+ 'Khải Phan' ]));
					node.style.display = '';
                    node.setAttribute('data-sbtv-loaded','true');
					poll.add(livePlayer.refresh, 1);
					livePlayer.refresh();
				});
			});
			return wrapper;
		});
	}
});
