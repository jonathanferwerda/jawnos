var piano;
var oscillator;



$(document).on('click', '#synth_toggle', function() {
	var url = '/manager/synth';
	var timestamp = Date.now();

	$.ajax({
		url: url,
		type: 'GET',
		data: { timestamp: timestamp, window_maker: 'yes' },
		success: function(response) {
			windowMaker(response);
			pianoInit();
		}
	});
});


$(document).on('click', '.piano_key', function() {
	var freq = $(this).attr('freq');
	var waveform = $('#synth_waveform').val();
	var length = $('#synth_length').val();
	var destination = $('#synth_destination').val();
	var sdata = { 'app': 'music', type: 'synth', freq: freq, waveform: waveform, length: length };
	var json = JSON.stringify(sdata);
	if (destination == 'browser') {
		oscillator = piano.createOscillator();
		var synth = document.getElementById('synthesizer');
		oscillator.frequency.value = freq;
		oscillator.connect(piano.destination);
		oscillator.type = waveform;
		oscillator.connect(piano.destination);
		synth.src = piano;
		oscillator.start();

		var pInt = setInterval(function() {
			
			oscillator.stop();
			clearInterval(pInt);
		},length * 1000);
	}
	else if (destination == 'sox') {
		ws['music'].send(json);
	}

});


function pianoInit() {
	piano = new AudioContext;
	oscillator = piano.createOscillator();
	var synth = document.getElementById('synthesizer');


	return piano;
}











