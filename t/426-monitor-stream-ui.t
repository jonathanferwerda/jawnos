# tests-for: public/js/manager/studio/07_layout.js templates/studio/markup.html.ep templates/studio/style.html.ep
# covers:    The controller's Monitor dropdown adds a stream to this tablet
#            above the target's physical outputs. The stream is started,
#            stopped and polled through monitor_stream; a physical device
#            stops the stream first and then keeps the old remote_device
#            write. Leaving remote mode or closing the window stops it, and
#            the status line never claims a stream the target refused.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $root   = "$FindBin::Bin/..";
my $layout = read_file("$root/public/js/manager/studio/07_layout.js");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");

# --- the dropdown markup -----------------------------------------------------
like($markup, qr/id="studio_remote_monitor"/, 'the Monitor select is still there');
like($markup, qr/id="studio_remote_monitor"[\s\S]{0,400}?<option value="__stream__"[^>]*class="studio_remote_monitor_stream"[^>]*>.*?Stream to this tablet/s,
	'the stream option is the first option in the select');
like($markup, qr/subs::ui\('Stream to this tablet'\)/, 'its words are translatable');
like($markup, qr/id="studio_remote_monitor_status"/, 'a short status line sits beside the select');
like($markup, qr{id="studio_remote_monitor"[\s\S]{0,700}?id="studio_remote_monitor_status"[\s\S]{0,240}?</span>\s*</span>}s,
	'the status line is inside the Monitor group, after the select');
like($markup, qr/Music receiver on this tablet/, 'the hint says the tablet receiver plays it');
like($markup, qr/Choose the output the controlled machine is monitored on/,
	'the physical-output wording survives');
like($markup, qr/id="studio_remote_monitor_picker"[^\n]*\bhidden\b/,
	'the whole group still starts hidden while this window drives itself');

# --- the sentinel and the physical rows --------------------------------------
like($layout, qr/var studioRemoteStreamOption = '__stream__';/,
	'JS names the stream sentinel once');
like($layout, qr/function studioRemoteStreamOptionEnsure\(\)/, 'one helper keeps the option present');
like($layout, qr/function studioRemoteMonitorLoad\(\)/, 'the loader is still the one list reader');
like($layout, qr{url: '/manager/studio/remote_devices'}, 'it still reads the target devices');
like($layout, qr/\.find\('option\.studio_remote_monitor_device'\)\.remove\(\)/,
	'a reload replaces only the physical rows');
like($layout, qr/addClass\('studio_remote_monitor_device'\)/, 'physical rows are marked as devices');
like($layout, qr/\.prependTo\(select\)/, 'the stream stays at the top of the rebuilt list');
like($layout, qr/current\.val\(studioRemoteStreaming \? studioRemoteStreamOption : \(studioRemoteMonitorCurrent \|\| ''\)\)/,
	'the remembered device stays visible unless a stream is running');

# --- starting the stream -----------------------------------------------------
like($layout, qr/function studioRemoteStreamStart\(\)/, 'one function starts the stream');
like($layout, qr{url: '/manager/studio/monitor_stream'}, 'it uses the monitor_stream route');
like($layout, qr/data: \{ action: 'start', target: target, output: 'stream' \}/,
	'with action start, the target and output stream');
like($layout, qr/!reply \|\| reply\.ok !== true \|\| !studioRemoteTruthy\(reply\.streaming\)/,
	'only a server streaming flag counts as started');
like($layout, qr/'Streaming to this tablet', 'on'/, 'success says it is streaming');
like($layout, qr/'Could not stream to this tablet', 'error'/, 'a refusal is an error, never a fake stream');
like($layout, qr/select\.val\(studioRemoteMonitorCurrent \|\| ''\)/,
	'a refused start puts the remembered device back in the select');

# --- stopping ----------------------------------------------------------------
like($layout, qr/function studioRemoteStreamStop\(done\)/, 'one function stops the stream');
like($layout, qr/data: \{ action: 'stop', target: target \}/, 'it posts action stop for the target');
like($layout, qr/'Stopped', 'stopped'/, 'the status line can say Stopped');
like($layout, qr/if \(done\) \{ done\(reply\); \}/, 'the stop callback runs after a response');
like($layout, qr/if \(done\) \{ done\(null\); \}/, 'and after a failed request, so the picker never wedges');
like($layout, qr/studioRemoteStreamStop\(function \(\) \{ studioRemoteDevicePick\(target, id\); \}\);/,
	'choosing a physical device stops the stream first');
like($layout, qr{url: '/manager/studio/remote_device'}, 'then keeps the old remote_device write');
like($layout, qr/data: \{ target: target, id: String\(id\) \}/, 'with the target and the device id');
like($layout, qr/function studioRemoteDevicePick\(target, id\)/, 'the device write has one helper');
like($layout, qr/studioRemoteMonitorCurrent = String\(reply\.current \|\| id\);/,
	'the chosen device becomes the visible current one');

# --- status polling ----------------------------------------------------------
like($layout, qr/function studioRemoteStreamStatusRequest\(\)/, 'status has its own request');
like($layout, qr/data: \{ action: 'status', target: target \}/, 'it posts action status for the target');
like($layout, qr/studioRemoteStreamPollTimer = setInterval\([\s\S]{0,200}?\}, 2000\)/,
	'it polls every two seconds while remote');
like($layout, qr/studioRemoteStreamPollStart\(\);\s*\n\s*studioRemotePollTimer = setInterval/,
	'remote mode starts it with the 500 ms state poll');
like($layout, qr/function studioRemotePollStop\(\) \{[\s\S]{0,200}?studioRemoteStreamPollStop\(\);/,
	'leaving remote mode stops it');
like($layout, qr/function studioRemoteStreamStatusApply\(reply\)/, 'the status answer is applied in one place');
like($layout, qr/studioRemoteStreamStatusShow\('Streaming to this tablet', 'on'\)/,
	'a running stream shows Streaming to this tablet');
like($layout, qr/reply\.error \? String\(reply\.error\) : 'Stopped'/, 'a stopped stream shows Stopped or the server error');
like($layout, qr/if \(select\.length && select\.val\(\) === studioRemoteStreamOption\) \{ select\.val\(studioRemoteMonitorCurrent \|\| ''\); \}/,
	'a stream that ended returns the picker to the current device');

# --- stop on leave and on close ----------------------------------------------
like($layout, qr/studioRemoteStreamStop\(\);\s*\n\s*studioRemoteTarget = '';/,
	'leaving remote mode stops the stream before forgetting the target');
like($layout, qr/\$\(document\)\.on\('click', '\.studio_close_button', function \(\) \{\s*\n\s*studioRemoteStreamStop\(\);/,
	'closing the Studio window stops the stream');
like($layout, qr/\$\(window\)\.on\('pagehide', function \(\) \{[\s\S]{0,400}?navigator\.sendBeacon\('\/manager\/studio\/monitor_stream'/,
	'a browser close sends a stop beacon');
like($layout, qr/body\.append\('action', 'stop'\);/, 'the beacon carries the stop action');

# --- no browser decoder in this change ---------------------------------------
my ($stream) = $layout =~ /(\/\/ ---- the controlled machine's own output[\s\S]*?\$\(document\)\.on\('change', '#studio_remote_monitor')/;
ok($stream && length($stream), 'the monitor block is present');
unlike($stream // '', qr/AudioWorklet|decodeAudioData|createScriptProcessor|new AudioContext/,
	'the tablet receiver plays it; no browser decoder is added');

# --- the status line has its own top-bar styles ------------------------------
like($style, qr/\.studio_remote_monitor_stream \{/, 'the stream option is styled apart');
like($style, qr/\.studio_remote_monitor_status \{/, 'the status line is styled');
like($style, qr/\.studio_remote_monitor_status\.on \{/, 'streaming has its own look');
like($style, qr/\.studio_remote_monitor_status\.error \{/, 'an error has its own look');
like($style, qr/\.studio_remote_monitor_status\.stopped/, 'Stopped is quiet');

done_testing();
