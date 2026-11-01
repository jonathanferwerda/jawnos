/* [[js-split]]
   junderground.js is part 1. The rest live in junderground/ in name order:
     01_junderground_iife.js - the junderground rooms IIFE
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// The Chat app's Rooms section: dial a junderground, see the door and the
// roster, grade it against the house's own people list, and join or leave.
// The switch URL and the house handle are the only settings; signing happens
// on the server, so the crest key never reaches this file.
