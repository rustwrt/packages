'use strict';
import { YtLoungeApi } from './lib/lounge.uc';
import { DeviceListener } from './lib/runtime.uc';
import { SponsorBlockClient, process_segments } from './lib/sponsorblock.uc';
import * as util from './lib/util.uc';
let uloop = require('uloop');
function check(ok, message) { if (!ok) die(message); }
function near(a,b) { return a >= b - 0.10 && a <= b + 0.10; }
uloop.init();
let client = SponsorBlockClient({ skip_categories: ['sponsor'], minimum_skip_length: 0, devices: [] });
check(client.minimum_skip_length == 0, 'zero minimum retained');
check(length(process_segments({segments: [{ segment: [0, 0.5], UUID: 'x', locked: 0 }]}, 0)[0]) == 1, 'short segment retained');
let video = 'abcdefghijk';
let segments = [{ start: 10, end: 20, UUID: ['x'] }, { start: 30, end: 40, UUID: ['y'] }];
client._segment_cache.set(video, segments, false);
let count = 0;
client.get_segments(video, (v) => { check(length(v)==2, 'cache hit'); count++; });
client.get_segments(video, (v) => { check(length(v)==2, 'second cache hit'); count++; });
check(count == 2 && length(keys(client._segment_pending)) == 0, 'cache synchronous, no fetch');
let listener = DeviceListener(client, {}, { screen_id: 'fixture', name: 'fixture', offset: 250 }, false);
check(near(listener.offset, 0.25), 'offset ms converted');
let delay, end;
listener._schedule_skip = (d, e) => { delay = d; end = e; };
listener._current_state={duration:100};
listener._time_start = util.monotonic_ms();
listener.lounge.playback_speed = 2;
listener._time_to_segment(segments, 5);
check(near(delay, 2.25) && end == 20, '2x speed and offset');
listener._time_start = util.monotonic_ms() - 1000;
listener._time_to_segment(segments, 5);
check(near(delay, 1.25) && end == 20, 'elapsed time at 2x');
listener._time_start = util.monotonic_ms();
listener._time_to_segment(segments, 15);
check(delay == 0 && end == 20, 'inside segment skips immediately');
listener._time_to_segment(segments, 21);
check(near(delay, 4.25) && end == 40, 'past segment not rewound');
let api = YtLoungeApi({ screen_id: 'fixture', lounge_token: 'token', mute_ads: true, skip_ads: true });
api._sid = 'sid'; api._gsession = 'gsid';
let skips = 0, mutes = [], done;
api._command = (name, args, cb) => {
    if (name == 'skipAd') { skips++; done = cb; }
    else if (name == 'setVolume') { push(mutes,args); api._process_event('onVolumeChanged',[args]); if(cb)cb(true); }
    else if (cb) cb(true);
};
api._process_event('onVolumeChanged', [{ volume: '0', muted: 'true' }]);
api._process_event('adPlaying', [{ isSkipEnabled: false }]);
api._process_event('onAdStateChange', [{ adState: '1082' }]);
check(length(mutes) == 0, 'preserve existing mute');
api._process_event('onVolumeChanged', [{ volume: '0', muted: 'false' }]);
api._process_event('adPlaying', [{ adVideoId: 'one', isSkipEnabled: true }]);
check(skips == 1 && length(mutes) == 1 && mutes[0].muted == 'true' && mutes[0].volume == '0', 'immediate ad mute and skip preserve volume zero');
done(false);
check(api._ad_retry_timer != null, 'retry scheduled without new event');
uloop.timer(1500, () => {
    check(skips == 2, 'retry fired');
    done(true);
    api._process_event('onAdStateChange', [{ adState: '1081', isSkipEnabled: true }]);
    check(skips == 2, 'no redundant automatic skip after accepted');
    api._process_event('onAdStateChange', [{ adState: '1082' }]);
    check(length(mutes) == 2 && mutes[1].muted == 'false' && mutes[1].volume == '0', 'restore only owned mute');
    check(api._ad_retry_timer == null, 'ad end cancels retries');
    print('Sensitivity checks OK: timing, cache, minimum, bounded retry, mute restoration\n');
    uloop.end();
});
uloop.run();
