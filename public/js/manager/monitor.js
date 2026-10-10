// The Monitor app: CPU/memory graphs and a sortable process list. The server
// reads cumulative CPU jiffies per pid and per core straight from /proc; every
// percentage is the difference between two polls, taken here.
//
// Cross-platform note (Termux/Android): /proc/stat and /proc/uptime are denied to
// apps, and other apps' /proc/<pid> entries are hidden. So on the phone the core
// graphs fall back to one aggregate "JawnOS" graph summed from the visible
// processes, ages show as "—", and the list holds JawnOS's own processes. Memory
// (/proc/meminfo) works everywhere.
var monitorInterval = null;
var monitorPrev = null;         // { at, map:{pid:ticks}, cpus:[{t,i}] }
var monitorRows = [];
var monitorSort = { key: 'cpu', dir: -1 };
var monitorCores = [];          // [{ canvas, ctx, label, hist:[] }]
var monitorCpuMode = null;      // 'cores' | 'aggregate'
var monitorMemHist = [];

$(document).on('click', '.process_monitor_toggle', function() {
	monitorOpener();
});

function monitorOpener() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/process_monitor',
		type: 'GET',
		data: { timestamp: timestamp, user_agent: navigator.userAgent },
		success: function(response) {
			windowMaker(response.window);
			monitorStart();
		}
	});
}

function monitorStart() {
	monitorPrev = null;
	monitorRows = [];
	monitorSort = { key: 'cpu', dir: -1 };
	monitorCores = [];
	monitorCpuMode = null;
	monitorMemHist = [];
	$('#monitor_cores').empty();
	monitorMarkHeaders();
	monitorPoll();
	if (monitorInterval) { clearInterval(monitorInterval); }
	monitorInterval = setInterval(function() {
		if (!$('#monitor').length || !$('#monitor').is(':visible')) {
			clearInterval(monitorInterval);
			monitorInterval = null;
			return;
		}
		monitorPoll();
	}, 2000);
}

function monitorPoll() {
	$.ajax({
		url: '/manager/process_monitor/data',
		type: 'GET',
		cache: false,
		success: function(d) {
			// ---- processes (also gives the aggregate-CPU fallback) ----
			var cur = {};
			var rows = [];
			(d.procs || []).forEach(function(p) {
				cur[p.p] = p.t;
				var cpu = 0;
				if (monitorPrev && monitorPrev.at && monitorPrev.map[p.p] !== undefined) {
					var dt = (d.at - monitorPrev.at) / 1000;
					if (dt > 0) { cpu = ((p.t - monitorPrev.map[p.p]) / d.clk) / dt * 100; }
				}
				var mem = d.mem_total ? (p.r * 4) / d.mem_total * 100 : 0;
				rows.push({ cpu: cpu, mem: mem, age: (p.a === undefined ? -1 : p.a), pid: parseInt(p.p, 10), name: p.n || '' });
			});
			var processCpuSum = rows.reduce(function(a, r) { return a + r.cpu; }, 0);
			monitorRows = rows;

			// ---- CPU series: per core when /proc/stat is readable (desktop),
			//      otherwise one aggregate line from the visible processes ----
			var haveCores = d.cpus && d.cpus.length > 0;
			var mode = haveCores ? 'cores' : 'aggregate';
			var series;
			if (haveCores) {
				series = d.cpus.map(function(c, idx) {
					var pct = 0;
					if (monitorPrev && monitorPrev.cpus && monitorPrev.cpus[idx]) {
						var dt = c.t - monitorPrev.cpus[idx].t;
						var di = c.i - monitorPrev.cpus[idx].i;
						if (dt > 0) { pct = (1 - di / dt) * 100; }
					}
					return Math.max(0, Math.min(100, pct));
				});
			}
			else {
				series = [ Math.max(0, Math.min(100, processCpuSum)) ];
			}
			if (monitorCpuMode !== mode || monitorCores.length !== series.length) {
				monitorBuildCores(mode, series.length);
			}
			series.forEach(function(p, i) {
				monitorCores[i].hist.push(p);
				if (monitorCores[i].hist.length > 60) { monitorCores[i].hist.shift(); }
				monitorCores[i].label.textContent = (mode === 'cores') ? (i + ' ' + Math.round(p) + '%') : 'JawnOS';
				if (monitorCores[i].wide) {
					var w = monitorCores[i].canvas.clientWidth || 600;
					if (monitorCores[i].canvas.width !== w) { monitorCores[i].canvas.width = w; }
				}
				monitorDrawBars(monitorCores[i].ctx, monitorCores[i].canvas, monitorCores[i].hist);
			});
			var avg = series.length ? series.reduce(function(a, b) { return a + b; }, 0) / series.length : 0;
			$('#monitor_cpu_total').text((haveCores ? avg.toFixed(0) + '% of ' + series.length + ' cores' : processCpuSum.toFixed(0) + '% (JawnOS)'));

			// ---- memory (instantaneous, works everywhere) ----
			var memPct = d.mem_total ? (d.mem_total - d.mem_avail) / d.mem_total * 100 : 0;
			monitorMemHist.push(memPct);
			if (monitorMemHist.length > 60) { monitorMemHist.shift(); }
			monitorDrawMem();
			var gb = 1048576;
			$('#monitor_mem_pct').text(memPct.toFixed(0) + '% (' + ((d.mem_total - d.mem_avail) / gb).toFixed(1) + '/' + (d.mem_total / gb).toFixed(1) + ' GB)');

			monitorPrev = { at: d.at, map: cur, cpus: d.cpus };
			monitorRender();
		}
	});
}

function monitorBuildCores(mode, count) {
	var row = $('#monitor_cores');
	row.empty();
	monitorCores = [];
	monitorCpuMode = mode;
	var wide = (mode === 'aggregate');
	for (var i = 0; i < count; i++) {
		var cv = document.createElement('canvas');
		if (wide) { cv.width = 900; cv.height = 60; } else { cv.width = 72; cv.height = 39; }
		var lbl = document.createElement('span');
		lbl.className = 'monitor_core_label';
		lbl.textContent = wide ? 'JawnOS' : i;
		var box = document.createElement('div');
		box.className = 'monitor_core' + (wide ? ' monitor_core_wide' : '');
		box.appendChild(cv);
		box.appendChild(lbl);
		row.append(box);
		monitorCores.push({ canvas: cv, ctx: cv.getContext('2d'), label: lbl, hist: [], wide: wide });
	}
}

function monitorBarColour(v) {
	var hue = (1 - Math.max(0, Math.min(100, v)) / 100) * 120;
	return 'hsl(' + hue.toFixed(0) + ',70%,45%)';
}

function monitorDrawBars(ctx, canvas, hist) {
	var w = canvas.width, h = canvas.height;
	ctx.clearRect(0, 0, w, h);
	var slot = w / 60;
	for (var i = 0; i < hist.length; i++) {
		var v = Math.max(0, Math.min(100, hist[i]));
		var bh = v / 100 * h;
		ctx.fillStyle = monitorBarColour(v);
		ctx.fillRect(i * slot, h - bh, Math.max(1, slot - 0.5), bh);
	}
}

function monitorDrawMem() {
	var cv = document.getElementById('monitor_mem_canvas');
	if (!cv) { return; }
	var w = cv.clientWidth || (cv.parentNode && cv.parentNode.clientWidth) || 300;
	if (cv.width !== w) { cv.width = w; }
	monitorDrawBars(cv.getContext('2d'), cv, monitorMemHist);
}

function monitorFormatAge(s) {
	if (s === undefined || s === null || s < 0) { return '—'; }
	s = Math.max(0, Math.floor(s));
	var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
	if (d) { return d + 'd ' + h + 'h'; }
	if (h) { return h + 'h ' + m + 'm'; }
	if (m) { return m + 'm ' + sec + 's'; }
	return sec + 's';
}

function monitorRender() {
	var s = monitorSort;
	var rows = monitorRows.slice().sort(function(a, b) {
		if (s.key === 'name') { return s.dir * String(a.name).localeCompare(String(b.name)); }
		if (s.key === 'age') {
			var ax = a.age < 0 ? Infinity : a.age, bx = b.age < 0 ? Infinity : b.age;
			return s.dir * (ax - bx);
		}
		return s.dir * ((a[s.key] || 0) - (b[s.key] || 0));
	});
	var html = '';
	var shown = rows.slice(0, 150);
	for (var i = 0; i < shown.length; i++) {
		var r = shown[i];
		var colour = r.cpu >= 25 ? ' style="color:#c0392b;font-weight:bold;"' : (r.cpu >= 5 ? ' style="color:#b9770e;"' : '');
		html += '<tr>'
			+ '<td style="text-align:right;"' + colour + '>' + r.cpu.toFixed(1) + '</td>'
			+ '<td style="text-align:right;">' + r.mem.toFixed(1) + '</td>'
			+ '<td style="text-align:right;">' + monitorFormatAge(r.age) + '</td>'
			+ '<td style="text-align:right;">' + r.pid + '</td>'
			+ '<td class="monitor_name">' + $('<div>').text(r.name).html() + '</td>'
			+ '</tr>';
	}
	$('#monitor_body').html(html || '<tr><td colspan="5">no processes</td></tr>');
}

function monitorMarkHeaders() {
	$('#monitor thead th.monitor_sort').each(function() {
		var th = $(this);
		var base = th.attr('data-label') || th.text().replace(/\s*[▲▼]+$/, '');
		th.attr('data-label', base);
		th.text(base + (monitorSort.key === th.attr('data-key') ? (monitorSort.dir > 0 ? ' ▲' : ' ▼') : ''));
	});
}

$(document).on('click', '#monitor thead th.monitor_sort', function() {
	var key = $(this).attr('data-key');
	if (monitorSort.key === key) { monitorSort.dir = -monitorSort.dir; }
	else { monitorSort.key = key; monitorSort.dir = (key === 'name' || key === 'pid' || key === 'age') ? 1 : -1; }
	monitorMarkHeaders();
	monitorRender();
});
