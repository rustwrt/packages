'use strict';
import { YtLoungeApi } from './lib/lounge.uc';
import { snapshot } from './lib/live.uc';
import * as util from './lib/util.uc';

function check(ok, message) { if (!ok) die(message); }
let api = YtLoungeApi({ screen_id: 'fixture', lounge_token: 'token', mute_ads: true, skip_ads: false });
let calls = [];
let pending;
api._command = (name, args, cb) => {
    push(calls, name);
    if (name == 'skipAd') pending = cb;
    else { if(name=='setVolume')api._process_event('onVolumeChanged',[args]); if(cb)cb(true); }
};
api._sid = 'sid'; api._gsession = 'gsession'; api._subscribe_active = true;
let listener = { lounge: api, phase: 'connected', _current_state: {state: 1, currentTime: 9, duration: 90, videoId: 'abcdefghijk'}, _time_start: util.monotonic_ms(), command_pending: false };
check(snapshot(listener).connection != 'connected', 'session alone not connected');
api._process_event('nowPlaying', [{ state: '1', videoId: 'abcdefghijk' }]);
check(snapshot(listener).connection == 'connected', 'screen confirms connected');
api._process_event('onVolumeChanged', [{ volume: '35', muted: 'false' }]);
api._process_event('adPlaying', [{ currentTime: '2', duration: '15', isSkipEnabled: 'false', adVideoId: 'ad1' }]);
let snap = snapshot(listener);
check(snap.ad_active && snap.playback == 1081 && snap.ad_position == 2 && snap.ad_duration == 15, 'ad progress');
check(!snap.ad_can_skip && !api.skip_ad(), 'non-skippable ad');
check(index(calls, 'setVolume') >= 0, 'automatic mute');
api._process_event('onAdStateChange', [{ adState: '1081', currentTime: '5', isSkipEnabled: 'true' }]);
check(snapshot(listener).ad_can_skip, 'manual skip available');
check(api.skip_ad() && !api.skip_ad(), 'one skip in flight');
check(snapshot(listener).ad_skip_pending, 'skip pending');
pending(true);
api._process_event('onAdStateChange', [{ adState: '1082' }]);
check(!snapshot(listener).ad_active && !snapshot(listener).ad_can_skip, 'ad ended');
api.skip_ads = true;
api._process_event('adPlaying', [{ isSkipEnabled: true, adVideoId: 'ad2' }]);
check(snapshot(listener).ad_skip_pending, 'automatic skip');
let count = length(calls);
api._process_event('onAdStateChange', [{ adState: '1081', isSkipEnabled: true }]);
check(length(calls) == count, 'automatic skip deduplicated');
pending(false);
check(snapshot(listener).ad_skip_pending && !api.ad.skip_pending, 'failed skip schedules retry');
api._process_event('nowPlaying', [{ state: '1' }]);
check(snapshot(listener).ad_active, 'ordinary nowPlaying does not clear ad');
api._process_event('onAdStateChange', [{adState:'1082'}]);
check(!snapshot(listener).ad_active, 'explicit end clears ad');
api._last_screen_event_time = util.monotonic_ms() - 40000;
api._process_event('noop', []);
check(snapshot(listener).connection == 'offline', 'noop cannot keep stale screen online');
print('Live ad state, manual/automatic skip and liveness checks OK\n');
