import os
import sys

root = "/home/jawn/jawnos/.worktrees/studio-track-monitor"


def edit(rel, pairs):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for old, new in pairs:
        if old not in text:
            sys.exit("NOT FOUND in %s:\n%r" % (rel, old[:400]))
        text = text.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("edited", rel)


# ---- the engine status names the machine's engine --------------------------
edit("lib/JawnOS/Controller/manager_misc9.pm", [
    (
        """\tif ($action eq 'status') {
\t\t$c->render(json => &JawnOS::Audio::Engine::audio_engine_status());
\t\treturn;
\t}""",
        """\tif ($action eq 'status') {
\t\tmy $status = &JawnOS::Audio::Engine::audio_engine_status();
\t\t$status = {} unless ref $status eq 'HASH';
\t\t# `installed` is the machine's engine, not this take: a staged binary
\t\t# that is not running is still the capture path the page must use
\t\t# instead of the browser microphone. `available` is the live socket.
\t\tmy $binary = &JawnOS::Audio::Engine::audio_engine_binary();
\t\t$status->{'installed'} = (defined $binary && length $binary && -x $binary) ? 1 : 0;
\t\t$status->{'available'} = &JawnOS::Audio::Engine::audio_engine_available() ? 1 : 0;
\t\t$c->render(json => $status);
\t\treturn;
\t}""",
    ),
])

# ---- a Monitor button on each track ----------------------------------------
edit("templates/studio/markup.html.ep", [
    (
        """\t\t\t\t\t\t\t<button class="studio_track_fx hover" channel="<%= $ch %>" hint="<%= &subs::ui('Show this track\\'s pedals') %>"><%= &subs::ui('FX') %></button>""",
        """\t\t\t\t\t\t\t<button class="studio_track_fx hover" channel="<%= $ch %>" hint="<%= &subs::ui('Show this track\\'s pedals') %>"><%= &subs::ui('FX') %></button>
\t\t\t\t\t\t\t<button class="studio_track_monitor hover" channel="<%= $ch %>" aria-pressed="false" hint="<%= &subs::ui('Hear this track\\'s live input through the monitor; one track at a time') %>"><%= &subs::ui('Monitor') %></button>""",
    ),
    (
        """\t\t\t\t<button type="button" class="studio_monitor_toggle hover" id="studio_monitor" aria-pressed="false" hint="<%= &subs::ui('Hear the recorded track and the live input, or the recorded track alone') %>"><%= &subs::ui('Monitor') %></button>
""",
        "",
    ),
])

edit("templates/studio/style.html.ep", [
    (
        """\t.studio_track_fx,
\t.studio_track_automation,
\t.studio_track_delete {""",
        """\t.studio_track_fx,
\t.studio_track_automation,
\t.studio_track_monitor,
\t.studio_track_delete {""",
    ),
    (
        """\t.studio_track_automation[aria-pressed="true"] {""",
        """\t.studio_track_automation[aria-pressed="true"],
\t.studio_track_monitor[aria-pressed="true"] {""",
    ),
])

edit("public/js/manager/studio/04_knobs.js", [
    (
        """\t\t\t\tsettings: response.settings,
\t\t\t\tautomations: {}
\t\t\t};""",
        """\t\t\t\tsettings: response.settings,
\t\t\t\tautomations: {},
\t\t\t\tmonitor: {}
\t\t\t};""",
    ),
])

# ---- the controls part: per-track monitor, and the backend policy ----------
backend = """// Which capture path this page has. The app's Oboe stream wins, then the house
// engine's staged binary; the browser microphone is only for a machine with
// neither. A native path never falls back to getUserMedia: a failure is shown,
// not quietly replaced by the browser.
var studioAudioBackendMemo;
var studioEngineInstalled = false;

function studioAudioBackend() {
\tif (studioAudioBackendMemo !== undefined) { return studioAudioBackendMemo; }
\tif (typeof studioNativeAudio === 'function' && studioNativeAudio()) {
\t\tstudioAudioBackendMemo = 'oboe';
\t}
\telse if (studioEngineInstalled) {
\t\tstudioAudioBackendMemo = 'engine';
\t}
\telse {
\t\tstudioAudioBackendMemo = 'browser';
\t}
\treturn studioAudioBackendMemo;
}

function studioAudioBackendReset() {
\tstudioAudioBackendMemo = undefined;
}

"""

track_monitor = """// The Monitor control is per track: each strip hears its own live input. Only
// one track is monitored at a time, because the engine (Oboe or the house
// engine) opens one input stream; pressing another track's Monitor moves it.
function studioMonitorOn(ch) {
\tch = String(ch);
\tif (!mixer || !mixer.monitor) { return false; }
\tif (studioEngineRecording && String(studioMonitoredChannel()) === ch) {
\t\treturn studioEngineMonitorArmed === true && studioEngineMonitorLevel > 0;
\t}
\treturn mixer.monitor[ch] ? true : false;
}

function studioMonitoredChannel() {
\tif (!mixer || !mixer.monitor) { return null; }
\tvar found = null;
\t$.each(mixer.monitor, function (ch, on) {
\t\tif (on && found === null) { found = String(ch); }
\t});
\treturn found;
}

function studioSetMonitor(ch, on, from_user) {
\tch = String(ch);
\tif (!mixer.monitor) { mixer.monitor = {}; }
\tif (on) {
\t\t$.each(mixer.monitor, function (other) { mixer.monitor[other] = 0; });
\t\tmixer.monitor[ch] = 1;
\t}
\telse { mixer.monitor[ch] = 0; }
\t// While an engine take records the same control arms the live input from
\t// this moment (1) or silences it (0); the recording so far is unaffected
\t// and the take keeps running either way.
\tif (studioEngineRecording) {
\t\tstudioEngineMonitorArmed = !!on;
\t\tstudioEngineMonitorLevel = on ? 1 : 0;
\t\tstudioEngineMonitorGain(on ? 1 : 0);
\t}
\tif (typeof studioApplyMonitor === 'function') { studioApplyMonitor(!!from_user); }
\tstudioMonitorButtonRender();
\tstudioSaver();
}

function studioMonitorButtonRender() {
\t$('.studio_track_monitor').each(function () {
\t\tvar ch = String($(this).attr('channel'));
\t\tvar on = studioMonitorOn(ch);
\t\t$(this).attr('aria-pressed', on ? 'true' : 'false')
\t\t\t.text(on ? studioListenText('Monitor on') : studioListenText('Monitor'));
\t});
\t$('.studio_config[setting="monitor"]').val(studioMonitorOn(studioSelectedChannel) ? 'yes' : 'no');
}

$(document).on('click', '.studio_track_monitor', function () {
\tvar ch = String($(this).attr('channel'));
\tstudioSetMonitor(ch, !studioMonitorOn(ch), true);
});"""

old_monitor = """// The transport\'s Monitor button is the same setting the config panel's
// "Monitor input" select carries: on, a take is heard with the live input;
// off, only the recorded track. One control updates the other. While an engine
// take records, the take's own live-input state is the truth: the take can arm
// input after it started, so the saved setting lags behind it.
function studioMonitorButtonOn() {
\tif (studioEngineRecording) {
\t\treturn studioEngineMonitorArmed === true && studioEngineMonitorLevel > 0;
\t}
\t// With no take recording, the engine's live Listen is the monitor: it is
\t// what makes an interface the engine owns audible at all.
\tif (typeof studioListenActive !== 'undefined' && studioListenActive) { return true; }
\treturn !!(mixer['time'] && mixer['time']['monitor'] == 'yes');
}

function studioMonitorButtonRender() {
\tvar on = studioMonitorButtonOn();
\t$('#studio_monitor').attr('aria-pressed', on ? 'true' : 'false')
\t\t.text(on ? studioListenText('Monitor on') : studioListenText('Monitor'));
}

$(document).on('click', '#studio_monitor', function () {
\tvar on = !studioMonitorButtonOn();
\t$('.studio_config[setting="monitor"]').val(on ? 'yes' : 'no').trigger('change');
\t// While an engine take records the same button arms the live input from
\t// this moment (1) or silences it (0); the recording so far is unaffected
\t// and the take keeps running either way. The take does not have to have
\t// started with Monitor on: the engine arms the input when this param
\t// arrives, so there is no armed-take guard here.
\tif (studioEngineRecording) {
\t\tstudioEngineMonitorArmed = on;
\t\tstudioEngineMonitorLevel = on ? 1 : 0;
\t\tstudioEngineMonitorGain(on ? 1 : 0);
\t}
\tstudioMonitorButtonRender();
});"""

edit("public/js/manager/studio/06_controls.js", [
    (
        "// The Android app registers window.JawnAudioOboe: a native duplex stream that",
        backend + "// The Android app registers window.JawnAudioOboe: a native duplex stream that",
    ),
    (old_monitor, track_monitor),
    (
        """\tif (setting == 'monitor') {
\t\tmixer['time']['monitor'] = value;
\t\tstudioApplyMonitor(true);
\t\tstudioSaver();
\t\treturn;
\t}""",
        """\tif (setting == 'monitor') {
\t\tmixer['time']['monitor'] = value;
\t\tstudioSetMonitor(studioSelectedChannel, value == 'yes', true);
\t\treturn;
\t}""",
    ),
    (
        """\t\t\t$('.studio_config[setting="monitor"]').val(mixer['time']['monitor'] || 'no');
\t\t\tstudioApplyMonitor();""",
        """\t\t\t$('.studio_config[setting="monitor"]').val(studioMonitorOn(studioSelectedChannel) ? 'yes' : 'no');
\t\t\tstudioApplyMonitor();""",
    ),
    # native start success releases the browser capture
    (
        """\tstudioNativeListening = true;
\tstudioListenSetActive(true);
\tstudioListenRender({ state: answer.state, channel: 0, frames: answer.frames, native: answer });""",
        """\tstudioNativeListening = true;
\tstudioListenSetActive(true);
\tif (typeof studioInputReleaseForMonitor === 'function') { studioInputReleaseForMonitor(); }
\tstudioListenRender({ state: answer.state, channel: 0, frames: answer.frames, native: answer });""",
    ),
    # native status: running releases, stopped resumes
    (
        """\tvar on = !!(data.running || data.waiting);
\tstudioListenSetActive(on);
\tif (!on) {
\t\tstudioNativeListening = false;
\t\tstudioListenPollStop();
\t\tif (data.error) { studioListenShowError(data.error); }
\t\telse if (data.microphone === false) { studioListenShowError(studioListenText('the microphone permission is not granted')); }
\t}""",
        """\tvar on = !!(data.running || data.waiting);
\tstudioListenSetActive(on);
\tif (on && data.running && typeof studioInputReleaseForMonitor === 'function') {
\t\tstudioInputReleaseForMonitor();
\t}
\tif (!on) {
\t\tstudioNativeListening = false;
\t\tstudioListenPollStop();
\t\tif (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
\t\tif (data.error) { studioListenShowError(data.error); }
\t\telse if (data.microphone === false) { studioListenShowError(studioListenText('the microphone permission is not granted')); }
\t}""",
    ),
    # native stop resumes
    (
        """\t\tstudioNativeListening = false;
\t\tstudioListenPollStop();
\t\tstudioListenSetActive(false);
\t\tif (bridge) { try { bridge.stop(); } catch (e) {} }
\t\treturn;""",
        """\t\tstudioNativeListening = false;
\t\tstudioListenPollStop();
\t\tstudioListenSetActive(false);
\t\tif (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
\t\tif (bridge) { try { bridge.stop(); } catch (e) {} }
\t\treturn;""",
    ),
    # engine listen start success releases
    (
        """\t\t\tstudioListenSetActive(true);
\t\t\tstudioListenRender(data);
\t\t\tstudioListenPollStart();""",
        """\t\t\tstudioListenSetActive(true);
\t\t\tif (typeof studioInputReleaseForMonitor === 'function') { studioInputReleaseForMonitor(); }
\t\t\tstudioListenRender(data);
\t\t\tstudioListenPollStart();""",
    ),
    # engine listen stop success resumes
    (
        """\t\tsuccess: function (data) {
\t\t\tstudioListenPollStop();
\t\t\tstudioListenSetActive(false);
\t\t\tdata = studioEngineAnswer(data);""",
        """\t\tsuccess: function (data) {
\t\t\tstudioListenPollStop();
\t\t\tstudioListenSetActive(false);
\t\t\tif (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
\t\t\tdata = studioEngineAnswer(data);""",
    ),
    # listen failure resumes
    (
        """\tstudioListenPollStop();
\tstudioListenSetActive(false);
\tvar error = (data && data.error) ? data.error : studioListenText('the audio engine did not answer');""",
        """\tstudioListenPollStop();
\tstudioListenSetActive(false);
\tif (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
\tvar error = (data && data.error) ? data.error : studioListenText('the audio engine did not answer');""",
    ),
])

# ---- studio.js: per-channel apply and engine availability -------------------
edit("public/js/manager/studio.js", [
    (
        """function studioApplyMonitor(from_user) {
\tvar on = mixer['time'] && mixer['time']['monitor'] == 'yes';
\t// The Android app's native stream is the phone's monitor: it opens the
\t// microphone itself, so the browser tap must stay muted or the input is
\t// heard twice. Only a person starts it, as with the engine's Listen.
\tvar native = !!(from_user && !studioEngineRecording
\t\t&& typeof studioNativeAudio === 'function' && studioNativeAudio());
\t$.each(studioAudio.channels, function (ch, c) {
\t\tif (c.monGain) { c.monGain.gain.value = (on && !native) ? 1 : 0; }
\t});
\t// With the engine up it owns the interface, so the browser cannot capture
\t// it. The same Monitor choice therefore drives the engine's live Listen;
\t// a machine without an engine simply keeps the browser path above.
\tif (from_user && !studioEngineRecording && typeof studioListenStart === 'function') {
\t\tif (on && !studioListenActive) { studioListenStart(true); }
\t\telse if (!on && studioListenActive) { studioListenStop(); }
\t}
\tif (typeof studioMonitorButtonRender === 'function') { studioMonitorButtonRender(); }
}""",
        """function studioApplyMonitor(from_user) {
\tvar active = (typeof studioMonitoredChannel === 'function') ? studioMonitoredChannel() : null;
\tvar backend = (typeof studioAudioBackend === 'function') ? studioAudioBackend() : 'browser';
\tvar nativeish = backend !== 'browser';
\t$.each(studioAudio.channels, function (ch, c) {
\t\tif (!c.monGain) { return; }
\t\tvar on = active !== null && String(ch) === String(active);
\t\tc.monGain.gain.value = (on && !nativeish) ? 1 : 0;
\t});
\t// A native path is the monitor and never falls back to the browser tap; a
\t// browser-only machine has no engine Listen to start, so the tap is it.
\tif (from_user && !studioEngineRecording && nativeish
\t\t&& typeof studioListenStart === 'function') {
\t\tif (active && !studioListenActive) { studioListenStart(false); }
\t\telse if (!active && studioListenActive) { studioListenStop(); }
\t}
\tif (typeof studioMonitorButtonRender === 'function') { studioMonitorButtonRender(); }
}""",
    ),
    (
        """\t\t\tdata = studioEngineAnswer(data);
\t\t\tif (data.ok !== true) {""",
        """\t\t\tdata = studioEngineAnswer(data);
\t\t\tstudioEngineInstalled = (data.installed === 1 || data.ok === true);
\t\t\tif (typeof studioAudioBackendReset === 'function') { studioAudioBackendReset(); }
\t\t\tif (data.ok !== true) {""",
    ),
    (
        """\t\t\tstudioEngineRecording = (data.state === 'recording');
\t\t\tstudioEngineRender(data);""",
        """\t\t\tstudioEngineRecording = (data.state === 'recording');
\t\t\tstudioEngineRender(data);
\t\t\tif (typeof studioApplyMonitor === 'function') { studioApplyMonitor(); }""",
    ),
    (
        """\tvar monitor = (mixer['time'] && mixer['time']['monitor'] == 'yes');""",
        """\tvar monitor = (typeof studioMonitoredChannel === 'function' && studioMonitoredChannel() !== null)
\t\t|| (mixer['time'] && mixer['time']['monitor'] == 'yes');""",
    ),
])

# ---- 05_inputs.js: release and resume the browser capture ------------------
capture_helpers = """// A native engine opens the microphone itself. While it monitors, the browser
// capture is released so one input is not opened twice; a track armed to
// record reopens it when the monitor stops. The browser is never the monitor
// on a native backend, only the recorder.
var studioMonitorInputReleased = false;

function studioInputReleaseForMonitor() {
\tif (studioMonitorInputReleased) { return; }
\tstudioMonitorInputReleased = true;
\t$.each(studioAudio.channels, function (ch) {
\t\tvar m = mixer[ch] && mixer[ch].media;
\t\tif (!m || !m.inRaw) { return; }
\t\tm.inRaw.getTracks().forEach(function (track) { track.stop(); });
\t\tm.inRaw = undefined;
\t\tm.in = null;
\t\tm.active = false;
\t\tstudioDetachInput(ch);
\t\tclearInterval(m.in_analyzer_timeout);
\t});
}

function studioInputResumeAfterMonitor() {
\tif (!studioMonitorInputReleased) { return; }
\tstudioMonitorInputReleased = false;
\t$('.studio_track').each(function () {
\t\tvar ch = String($(this).attr('data-channel'));
\t\tvar state = $('.studio_track_arm[channel="' + ch + '"]').attr('state');
\t\tif (state === 'rec' || state === 'loop') { studioInputStreamGrabber(ch, state); }
\t});
}

"""

edit("public/js/manager/studio/05_inputs.js", [
    ("async function studioInputStreamGrabber(channel,state) {", capture_helpers + "async function studioInputStreamGrabber(channel,state) {"),
])

# ---- tests ------------------------------------------------------------------
edit("t/338-studio-engine-panel.t", [
    (
        """like($controls_js, qr/'#studio_monitor'/, 'the transport Monitor button is bound');""",
        """like($markup, qr/class="studio_track_monitor/, 'every track carries a Monitor button');
like($controls_js, qr/\\.studio_track_monitor/, 'the track Monitor buttons are bound');
like($controls_js, qr/function studioSetMonitor/, 'one track is monitored at a time');
like($controls_js, qr/function studioMonitoredChannel/, 'the monitored track is readable');""",
    ),
    (
        """like($controls_js, qr/studioApplyMonitor\\(true\\)/, 'the monitor setting tells the engine path it was a person');""",
        """like($controls_js, qr/function studioAudioBackend/, 'a native backend is chosen');
like($controls_js, qr/studioAudioBackendMemo = 'oboe'/, 'Oboe wins');
like($controls_js, qr/studioEngineInstalled/, 'then the house engine');
like($controls_js, qr/studioInputReleaseForMonitor/, 'the browser capture is released while a native stream monitors');""",
    ),
    (
        """like($controls_js, qr/typeof studioListenActive !== 'undefined' && studioListenActive/,
\tthe transport button follows the live Listen');""",
        """like($studio_js, qr/var nativeish = backend !== 'browser'/,
\t'the browser tap is not the monitor on a native backend');""",
    ),
    (
        """like($studio_js, qr/studioListenStart\\(true\\)/, 'a user Monitor starts the engine Listen');""",
        """like($studio_js, qr/studioListenStart\\(false/, 'a user Monitor starts the engine Listen without a browser fallback');""",
    ),
    (
        """like($body, qr/Monitor starts the engine's live Listen/,
\t'help says Monitor starts the engine Listen with no take');""",
        """like($body, qr/Monitor starts the engine's live Listen/,
\t'help says Monitor starts the engine Listen with no take');
like($body, qr/Each track's Monitor button/, 'help says Monitor is per track');
like($body, qr/one track is monitored at a time/, 'and that one input is monitored at a time');""",
    ),
])

edit("t/339-studio-layout.t", [
    (
        """like($markup, qr/id="studio_monitor"[^>]*aria-pressed="false"/,
\t'the transport carries a Monitor button');""",
        """like($markup, qr/class="studio_track_monitor/,
\t'every track carries a Monitor button');""",
    ),
])

print("done")
