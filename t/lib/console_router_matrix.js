const fs=require('fs'), vm=require('vm'), assert=require('assert');
const code=fs.readFileSync(process.argv[2],'utf8');
const calls=[];
const ctx={console:{warn:()=>{},error:()=>{},log:()=>{}},JSON,Date,String,Number,Array,Object,Math,
  $: function(){ return {length:0, find(){return this;}, filter(){return this;}, attr(){return '';}, html(){return this;}, val(){return this;}, text(){return this;}, remove(){return this;}, show(){return this;}, hide(){return this;}, trigger(){return this;}, is(){return false;}, first(){return this;} }; },
  document:{hidden:false}, window:{}, location:{reload(){calls.push(['reload',[]]);}}
};
vm.createContext(ctx); vm.runInContext(code,ctx);
for (const k of Object.keys(ctx.jawnosConsoleCommands)) { ctx.jawnosConsoleCommands[k]=(a)=>calls.push([k,a]); }
function run(s){ calls.length=0; const ok=ctx.jawnosConsoleRun(s); return {ok, calls: JSON.parse(JSON.stringify(calls))}; }
const cases = [
 ["appointmentDetailGrabber('house','u1');", 'appointmentDetailGrabber', ['house','u1']],
 ['appointmentDetailGrabber("house","u1");', 'appointmentDetailGrabber', ['house','u1']],
 ["appointmentGrabber('house','123','ws');", 'appointmentGrabber', ['house','123','ws']],
 ["if (!document.hidden) { appointmentGrabber('house','123','ws'); }", 'appointmentGrabberIfVisible', ['house','123','ws']],
 ["jpStop('house','rec','u1');", 'jpStop', ['house','rec','u1']],
 ["configurationReloader('house');", 'configurationReloader', ['house']],
 ['listProxy(123,"u1");', 'listProxy', [123,'u1']],
 ['setProxy(123,"u1");', 'setProxy', [123,'u1']],
 ['travelViewer(123,"u1");', 'travelViewer', [123,'u1']],
 ["continent_record({'uuid':'u1', 'app':'house','purpose':'app','timestamp':'123','navigation':\"once\" });", 'continentRecord', [{uuid:'u1',app:'house',purpose:'app',timestamp:'123',navigation:'once'}]],
 ["$('.assistant_content[uuid=\"u1\"]').html('hi');", 'setHtml', ['u1','hi']],
 ["$('.appointment[app=\"house\"]').find('.app_measure[measure=\"m\"]').val('7');", 'setMeasure', ['house','m','7']],
 ["$('.appointment[app=\"house\"]').find('.app_measure_display[measure=\"m\"]').text('7');", 'setMeasureText', ['house','m','7']],
 ["$('.wind[app=\"house\"]').find('.email_compose_form').attr('uuid', 'u1');", 'setEmailForm', ['house','u1']],
 ["$('.email_message[uuid=\"u1\"]').remove();$('.mailbox_message[uuid=\"u1\"]').remove();", 'removeEmail', ['u1']],
 ["$('.mailbox_message[uuid=\"u1\"]').remove();", 'removeMailbox', ['u1']],
 ["$('.appointment_detail[app=\"house\"][uuid=\"u1\"]').remove();", 'removeAppointmentDetail', ['house','u1']],
 ["$('.measures_pv[app=\"house\"][measure=\"m\"]').text('7');", 'setMeasuresPv', ['house','m','7']],
 ["$('.app_act[app=\"house\"][type=\"web\"]').attr('web', 'yes').show();", 'setAppAct', ['house','yes']],
 ["$('.app_act[app=\"house\"][type=\"web\"]').attr('web', '').hide();", 'setAppAct', ['house','']],
 ["$('.appointment[app=\"house\"]').find('.enabler[type=\"toggle\"').attr('status','on').attr('src', 'x').attr('style', 'y');", 'setToggle', ['house','on','x','y']],
 ["$('.appointment[app=\"house\"]').find('.enabler[type=\"toggle\"').attr('status','on').attr('src', 'x');", 'setToggle', ['house','on','x',null]],
 ['$(".myapp_close_button").trigger("click");', 'closeButton', ['myapp']],
 ['tunnelLister()', 'tunnelLister', []],
 ['notesReload();', 'notesReload', []],
 ['marketScanArrived();', 'marketScanArrived', []],
 ['location.reload()', 'reload', []],
 ["$('#embedded_ota_uploader_wait').show()", 'show', ['embedded_ota_uploader_wait']],
 ["jawnosMediaLockdown(\"private\")", 'jawnosMediaLockdown', ['private']],
 ["appWindowOpener(\"music\", 123, {})", 'appWindowOpener', ['music',123,{}]],
 ["musicToggle([\"a\",\"b\"], 1)", 'musicToggle', [['a','b'],1]],
 [{cmd:'appointmentGrabber', args:['house','123']}, 'appointmentGrabber', ['house','123']],
 [{cmd:'appointmentDetailGrabber', args:['house','u1']}, 'appointmentDetailGrabber', ['house','u1']],
 [{cmd:'mediaUnlock', args:['music','tok']}, 'mediaUnlock', ['music','tok']],
 [{cmd:'setAppointmentAttr', args:['house','status','on']}, 'setAppointmentAttr', ['house','status','on']],
 [{cmd:'otaUploaderPercent', args:['uploading','42%']}, 'otaUploaderPercent', ['uploading','42%']],
 [{cmd:'jawnosClockAlarmRing', args:[{uuid:'a1'}]}, 'jawnosClockAlarmRing', [{uuid:'a1'}]],
 [{cmd:'ticketList', args:[]}, 'ticketList', []]
];
let fail=0;
for (const [s,cmd,args] of cases) {
  const r=run(s);
  try { assert(r.ok, 'not accepted: '+s); assert.strictEqual(r.calls[0][0], cmd, 'cmd for '+s); assert.deepStrictEqual(r.calls[0][1], args, 'args for '+s); }
  catch(e){ fail++; console.log('FAIL', e.message, '=>', JSON.stringify(r)); }
}
for (const bad of ['alert(1);', "$('body').remove();", 'eval("x")', 'constructor()', {cmd:'alert', args:['1']}, {cmd:'constructor', args:[]}]) {
  const r=run(bad);
  if (r.ok) { fail++; console.log('FAIL accepted bad:', JSON.stringify(bad)); }
}
console.log(fail ? ('FAILURES '+fail) : 'router-ok '+cases.length);
process.exit(fail?1:0);
