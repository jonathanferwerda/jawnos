var guests = [];
var resident = {
	'pc': {}
};
var citizen = {
	'pc': {}
};
const servers = { 'iceServers': [{'urls': [ 'stun:stun.1.google.com:19302' ]}]};

function pml(app) {
    citizen['pc'][app] = new RTCPeerConnection(servers); // eslint-disable-line new-cap
    console.log('Created local peer connection object ' + app);
    citizen['pc'][app].onicecandidate = e => onIceCandidate(citizen['pc'][app], e);
    resident['pc'][app] = new RTCPeerConnection(servers); // eslint-disable-line new-cap
    console.log('Created remote peer connection object pc2');
    resident['pc'][app].onicecandidate = e => onIceCandidate(resident['pc'][app], e);
    resident['pc'][app].ontrack = gotRemoteStream;
    citizen['pc'][app].getTracks().forEach(track => citizen['pc'][app].addTrack(track, citizen['pc'][app]));
    resident['pc'][app].createOffer().then(gotDescription1).catch(error => console.log(`createOffer failed: ${error}`));
		console.log(servers);
    stream.oninactive = () => {
      console.log('Stream inactive:', stream);
      startButton.disabled = false;
      stopButton.disabled = true;
    };

    localStream = stream;
}

function pmo() {

}

function pmc() {

}

function pmh() {

}