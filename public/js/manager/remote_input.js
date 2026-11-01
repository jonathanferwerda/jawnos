/* [[js-split]]
   remote_input.js is part 1. The rest live in remote_input/ in name order:
     01_remote_control_iife.js - the remote keyboard and mouse IIFE
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// Remote keyboard and mouse for the Assistant's remote_control panel.
//
// The panel names a peer, and this file borrows this machine's pointer and keys
// for it. The chosen edge says where that screen sits beside this view: taking
// control enters from the touching edge, and coming back to that same edge (or
// pressing Escape, or pressing Release) hands the pointer and keys home again.
//
// Events are batched and sent through this machine's manager, which relays the
// batch to the peer over the signed rail; the peer's own manager injects it
// with the same backends the T-Deck's teletype uses (remote_input.pl). Moves are
// absolute fractions of the peer's screen, so a dropped batch cannot leave the
// pointer drifting.
