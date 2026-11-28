package gb;
use strict;
no warnings;

# The Search app's built-in engines. `url` is what the words are appended to
# (or a template carrying {q}); `kind` says how to read the answer: rss (a
# feed), ddg (DuckDuckGo's Instant Answer API), mediawiki (a MediaWiki search
# API), or html (links read from the page). `rss` is the feed form when the
# engine offers one. `group` keeps the configuration list tidy.
#
# These are the engines we can reach without a key. An engine that answers a
# server with a JavaScript shell still appears: its row is a link that opens
# that engine in the JawnOS Browser. A person can add another engine from the
# Browser (the + Search button), and enable or disable any of them in Search's
# settings panel.
our @search_default_engines = qw(bing brave duckduckgo wikipedia);
our @search_engines = (
	{ id => 'bing',       name => 'Bing',            group => 'general',   kind => 'rss',       url => 'https://www.bing.com/search?q=', rss => 'https://www.bing.com/search?format=rss&q=' },
	{ id => 'brave',      name => 'Brave Search',    group => 'general',   kind => 'html',      url => 'https://search.brave.com/search?q=', home => 'https://search.brave.com/' },
	{ id => 'duckduckgo', name => 'DuckDuckGo',      group => 'general',   kind => 'ddg',       url => 'https://duckduckgo.com/?q=', home => 'https://duckduckgo.com/' },
	{ id => 'google',     name => 'Google',          group => 'general',   kind => 'html',      url => 'https://www.google.com/search?q=', home => 'https://www.google.com/' },
	{ id => 'startpage',  name => 'Startpage',       group => 'general',   kind => 'html',      url => 'https://www.startpage.com/sp/search?query=', home => 'https://www.startpage.com/' },
	{ id => 'ecosia',     name => 'Ecosia',          group => 'general',   kind => 'html',      url => 'https://www.ecosia.org/search?q=', home => 'https://www.ecosia.org/' },
	{ id => 'qwant',      name => 'Qwant',           group => 'general',   kind => 'html',      url => 'https://www.qwant.com/?q=', home => 'https://www.qwant.com/' },
	{ id => 'mojeek',     name => 'Mojeek',          group => 'general',   kind => 'html',      url => 'https://www.mojeek.com/search?q=', home => 'https://www.mojeek.com/' },
	{ id => 'yahoo',      name => 'Yahoo',           group => 'general',   kind => 'html',      url => 'https://search.yahoo.com/search?p=', home => 'https://search.yahoo.com/' },
	{ id => 'yandex',     name => 'Yandex',          group => 'general',   kind => 'html',      url => 'https://yandex.com/search/?text=', home => 'https://yandex.com/' },
	{ id => 'baidu',      name => 'Baidu',           group => 'general',   kind => 'html',      url => 'https://www.baidu.com/s?wd=', home => 'https://www.baidu.com/' },
	{ id => 'naver',      name => 'Naver',           group => 'general',   kind => 'html',      url => 'https://search.naver.com/search.naver?query=', home => 'https://search.naver.com/' },
	{ id => 'seznam',     name => 'Seznam',          group => 'general',   kind => 'html',      url => 'https://search.seznam.cz/?q=', home => 'https://search.seznam.cz/' },
	{ id => 'swisscows',  name => 'Swisscows',       group => 'general',   kind => 'html',      url => 'https://swisscows.com/en/web?query=', home => 'https://swisscows.com/' },
	{ id => 'metager',    name => 'MetaGer',         group => 'general',   kind => 'html',      url => 'https://metager.org/meta/meta.ger3?eingabe=', home => 'https://metager.org/' },
	{ id => 'marginalia', name => 'Marginalia',      group => 'general',   kind => 'html',      url => 'https://search.marginalia.nu/search?query=', home => 'https://search.marginalia.nu/' },
	{ id => 'stract',     name => 'Stract',          group => 'general',   kind => 'html',      url => 'https://stract.com/search?q=', home => 'https://stract.com/' },
	{ id => 'wiby',       name => 'Wiby',            group => 'general',   kind => 'html',      url => 'https://wiby.me/?q=', home => 'https://wiby.me/' },
	{ id => 'rightdao',   name => 'Right Dao',       group => 'general',   kind => 'html',      url => 'https://rightdao.com/search?query=', home => 'https://rightdao.com/' },
	{ id => 'presearch',  name => 'Presearch',       group => 'general',   kind => 'html',      url => 'https://presearch.com/search?q=', home => 'https://presearch.com/' },
	{ id => 'searx',      name => 'SearXNG',         group => 'general',   kind => 'html',      url => 'https://searx.be/search?q=', home => 'https://searx.be/' },
	{ id => 'aol',        name => 'AOL',             group => 'general',   kind => 'html',      url => 'https://search.aol.com/aol/search?q=', home => 'https://search.aol.com/' },
	{ id => 'ask',        name => 'Ask',             group => 'general',   kind => 'html',      url => 'https://www.ask.com/web?q=', home => 'https://www.ask.com/' },
	{ id => 'dogpile',    name => 'Dogpile',         group => 'general',   kind => 'html',      url => 'https://www.dogpile.com/serp?q=', home => 'https://www.dogpile.com/' },
	{ id => 'lycos',      name => 'Lycos',           group => 'general',   kind => 'html',      url => 'https://search.lycos.com/web/?q=', home => 'https://search.lycos.com/' },
	{ id => 'yep',        name => 'Yep',             group => 'general',   kind => 'html',      url => 'https://yep.com/web?q=', home => 'https://yep.com/' },
	{ id => 'wikipedia',  name => 'Wikipedia',       group => 'reference', kind => 'mediawiki', url => 'https://en.wikipedia.org/w/index.php?search=', home => 'https://en.wikipedia.org/' },
	{ id => 'wiktionary', name => 'Wiktionary',      group => 'reference', kind => 'mediawiki', url => 'https://en.wiktionary.org/w/index.php?search=', home => 'https://en.wiktionary.org/' },
	{ id => 'scholar',    name => 'Google Scholar',  group => 'reference', kind => 'html',      url => 'https://scholar.google.com/scholar?q=', home => 'https://scholar.google.com/' },
	{ id => 'wolfram',    name => 'Wolfram Alpha',   group => 'reference', kind => 'html',      url => 'https://www.wolframalpha.com/input?i=', home => 'https://www.wolframalpha.com/' },
	{ id => 'dictionary', name => 'Dictionary',      group => 'reference', kind => 'html',      url => 'https://www.dictionary.com/browse/', home => 'https://www.dictionary.com/' },
	{ id => 'thesaurus',  name => 'Thesaurus',       group => 'reference', kind => 'html',      url => 'https://www.thesaurus.com/browse/', home => 'https://www.thesaurus.com/' },
	{ id => 'arxiv',      name => 'arXiv',           group => 'reference', kind => 'html',      url => 'https://arxiv.org/search/?query=', home => 'https://arxiv.org/' },
	{ id => 'pubmed',     name => 'PubMed',          group => 'reference', kind => 'html',      url => 'https://pubmed.ncbi.nlm.nih.gov/?term=', home => 'https://pubmed.ncbi.nlm.nih.gov/' },
	{ id => 'openlibrary',name => 'Open Library',    group => 'reference', kind => 'html',      url => 'https://openlibrary.org/search?q=', home => 'https://openlibrary.org/' },
	{ id => 'archive',    name => 'Internet Archive',group => 'reference', kind => 'html',      url => 'https://archive.org/search?query=', home => 'https://archive.org/' },
	{ id => 'stackoverflow',name => 'Stack Overflow',group => 'reference', kind => 'html',     url => 'https://stackoverflow.com/search?q=', home => 'https://stackoverflow.com/' },
	{ id => 'github',     name => 'GitHub',          group => 'reference', kind => 'html',      url => 'https://github.com/search?q=', home => 'https://github.com/' },
	{ id => 'hn',         name => 'Hacker News',     group => 'reference', kind => 'html',      url => 'https://hn.algolia.com/?q=', home => 'https://news.ycombinator.com/' },
	{ id => 'youtube',    name => 'YouTube',         group => 'media',     kind => 'html',      url => 'https://www.youtube.com/results?search_query=', home => 'https://www.youtube.com/' },
	{ id => 'spotify',    name => 'Spotify',         group => 'media',     kind => 'html',      url => 'https://open.spotify.com/search/', home => 'https://open.spotify.com/' },
	{ id => 'bandcamp',   name => 'Bandcamp',        group => 'media',     kind => 'html',      url => 'https://bandcamp.com/search?q=', home => 'https://bandcamp.com/' },
	{ id => 'soundcloud', name => 'SoundCloud',      group => 'media',     kind => 'html',      url => 'https://soundcloud.com/search?q=', home => 'https://soundcloud.com/' },
	{ id => 'imdb',       name => 'IMDb',            group => 'media',     kind => 'html',      url => 'https://www.imdb.com/find/?q=', home => 'https://www.imdb.com/' },
	{ id => 'rottentomatoes',name => 'Rotten Tomatoes',group => 'media',   kind => 'html',      url => 'https://www.rottentomatoes.com/search?search=', home => 'https://www.rottentomatoes.com/' },
	{ id => 'reddit',     name => 'Reddit',          group => 'media',     kind => 'html',      url => 'https://www.reddit.com/search/?q=', home => 'https://www.reddit.com/' },
	{ id => 'amazon',     name => 'Amazon',          group => 'shopping',  kind => 'html',      url => 'https://www.amazon.ca/s?k=', home => 'https://www.amazon.ca/' },
	{ id => 'bestbuy',    name => 'Best Buy',        group => 'shopping',  kind => 'html',      url => 'https://www.bestbuy.ca/en-ca/search?searchText=', home => 'https://www.bestbuy.ca/' },
	{ id => 'ebay',       name => 'eBay',            group => 'shopping',  kind => 'html',      url => 'https://www.ebay.ca/sch/i.html?_nkw=', home => 'https://www.ebay.ca/' },
	{ id => 'walmart',    name => 'Walmart',         group => 'shopping',  kind => 'html',      url => 'https://www.walmart.ca/search?q=', home => 'https://www.walmart.ca/' },
	{ id => 'costco',     name => 'Costco',          group => 'shopping',  kind => 'html',      url => 'https://www.costco.ca/CatalogSearch?keyword=', home => 'https://www.costco.ca/' },
	{ id => 'homedepot',  name => 'Home Depot',      group => 'shopping',  kind => 'html',      url => 'https://www.homedepot.ca/search?q=', home => 'https://www.homedepot.ca/' },
	{ id => 'ikea',       name => 'IKEA',            group => 'shopping',  kind => 'html',      url => 'https://www.ikea.com/ca/en/search/?q=', home => 'https://www.ikea.com/ca/en/' },
	{ id => 'ctv',        name => 'CTV News',        group => 'news',      kind => 'html',      url => 'https://www.ctv.ca/search/', home => 'https://www.ctv.ca/' },
	{ id => 'cbc',        name => 'CBC',             group => 'news',      kind => 'html',      url => 'https://www.cbc.ca/search?q=', home => 'https://www.cbc.ca/' },
	{ id => 'bbc',        name => 'BBC',             group => 'news',      kind => 'html',      url => 'https://www.bbc.co.uk/search?q=', home => 'https://www.bbc.co.uk/' },
	{ id => 'reuters',    name => 'Reuters',         group => 'news',      kind => 'html',      url => 'https://www.reuters.com/site-search/?query=', home => 'https://www.reuters.com/' },
	{ id => 'perplexity', name => 'Perplexity',      group => 'general',   kind => 'html',      url => 'https://www.perplexity.ai/search?q=', home => 'https://www.perplexity.ai/' },
	{ id => 'kagi',       name => 'Kagi',            group => 'general',   kind => 'html',      url => 'https://kagi.com/search?q=', home => 'https://kagi.com/' },
);

# The Guide's tools, declared once. Each entry names the action the model may
# choose, the arguments it takes, and what it does; the prompt, the allow-list
# and (in time) the remote verb channel are all generated from this, so adding a
# tool is one entry here, not a change in three files.
#
# `planned` marks a tool whose resolver is not built yet: it is declared so the
# shape is settled, and is only offered to the model once its resolver lands.
our @guide_tools = (
	{ name => 'find', args => { query => 'a name' }, example => '{"action":"find","query":"a name"}',
	  desc => 'search their records by name; returns matching apps and files, the named things in the other tables, and first, last and next (the dates of the oldest, newest and next such matches - use these to answer "when did I last/first ...")' },
	{ name => 'lookup', args => { query => 'a name or word' }, example => '{"action":"lookup","query":"my address"}',
	  desc => 'read the person\'s own value for a field you are about to fill: searches the appointments log, notes and mail for the words and returns the matching rows\' own phone, email, note, subject and body text. Use it to take a value from this house (never a password or a credential), then fill the page with it' },
	{ name => 'open_gallery', args => { names => [ 'a', 'b' ], app => 'x', search => 'x' }, example => '{"action":"open_gallery","names":["a","b"]}',
	  desc => 'open the photo browser to one or more named things, each resolved to the app that holds it ("app":"x" scopes to one; "search":"x" filters by text)' },
	{ name => 'open_app', args => { app => 'gallery' }, example => '{"action":"open_app","app":"gallery"}',
	  desc => "open one app's window" },
	{ name => 'say', args => { text => '...' }, example => '{"action":"say","text":"..."}',
	  desc => 'answer in words, then stop' },
	{ name => 'ask', args => { text => '...' }, example => '{"action":"ask","text":"..."}',
	  desc => 'ask the person a question, then stop' },
	{ name => 'done', args => { text => '...' }, example => '{"action":"done","text":"..."}',
	  desc => 'you have finished; say briefly what you did' },
	{ name => 'play_music', args => { query => 'artist, track, show or episode', shuffle => 0 }, example => '{"action":"play_music","query":"friends"}',
	  desc => 'search the music and video library for what the person named - a show, an artist, an album, a track - and play every match as a list of episodes or songs; set "shuffle" to 1 when they ask for a shuffle' },
	{ name => 'remote', args => { machine => 'the table', text => 'play Ben Folds Five Mess' }, example => '{"action":"remote","machine":"the table","text":"play ..."}',
	  desc => "send a command to one of the person's other machines, named in their words (\"the table\", \"the phone\"); that machine's own guide reads it, so it runs there" },
	{ name => 'show_place', args => { place => 'a place name' }, example => '{"action":"show_place","place":"Sarnia"}',
	  desc => 'open the travel map and centre it on a place, deduced from the home plates of the things named for it (offline; no geocoder)' },
	{ name => 'where_when', args => { when => 'a date or time' }, example => '{"action":"where_when","when":"2025-09-18"}',
	  desc => 'say where the person was at a time, read from the recorded place fixes; give when as an absolute date (YYYY-MM-DD) or a timestamp, never a relative phrase' },
	{ name => 'measure', args => { measure => 'walk or weight', period => 'month', target => '180' }, example => '{"action":"measure","measure":"walk","period":"month"}',
	  desc => 'answer a measured question: "walk" sums the distance walked over the period (day, week, month, year); "weight" reads the person\'s latest weight and projects when the target (their set budget) is reached' },
	{ name => 'translate', args => { text => '...', to => 'French' }, example => '{"action":"translate","text":"Good morning","to":"French"}',
	  desc => 'translate words or a phrase into a language the translation engine offers; give "to" as the person named it (French, 日本語, pt-BR). Use for "translate this" and "how do you say ... in ..."' },
	{ name => 'translate_page', args => { to => 'French' }, example => '{"action":"translate_page","to":"French"}',
	  desc => 'translate the visible interface of the current window (labels, buttons, help text) into the named language on demand, without changing the saved interface language' },
	{ name => 'translate_languages', args => { }, example => '{"action":"translate_languages"}',
	  desc => 'list every language the translation engine offers; use when the person asks what languages you can translate' },
	{ name => 'page', args => { do => 'fill', fields => [ { field => 'f1', value => '...' } ], target => 'b1' }, example => '{"action":"page","do":"fill","fields":[{"field":"f1","value":"..."}]}',
	  desc => 'work with the window the person attached you to: "do":"fill" sets every field in "fields" (a list of {"field":"f1","value":"..."}), "do":"read" returns the named field or all of them, and "do":"press" presses the button named by "target". Use only the field and button keys from the PAGE ON SCREEN block, and prefer this to telling the person where to click' },
	{ name => 'app', args => { app => 'market', do => 'add_item', params => { text => 'milk' } }, example => '{"action":"app","app":"market","do":"add_item","params":{"text":"milk"}}',
	  desc => 'run one action the app\'s help topic lists under APP ACTIONS. Use only a listed "do" and only its parameter names, with the values in "params". A read runs at once; a write is proposed first, so never say it is done until the result says so' },
	{ name => 'weather', args => { when => 'now', where => 'Sarnia', what => 'now' }, example => '{"action":"weather","when":"tomorrow","where":"Sarnia"}',
	  desc => 'read the forecast for now or tomorrow, optionally for a place the house knows; set "what" to now, precip, highlow or wind. Use it for "what is the weather", "will it rain", "the high tomorrow"' },
	{ name => 'history', args => { query => 'Brian Coulbeck', which => 'last', kind => 'person' }, example => '{"action":"history","query":"Brian Coulbeck","which":"last","kind":"person"}',
	  desc => 'answer when the person last, first or next saw or visited the named person or place, how many times, or how long the last visit lasted. Set "which" to last, first, next, count or duration, and "kind" to person or visit. The name is the person or place in their words' },
	{ name => 'generate', args => { kind => 'image', prompt => 'a full description', app => 'the appointment it is for' }, example => '{"action":"generate","kind":"image","prompt":"a red barn at dawn","app":"kitchen renovation"}',
	  desc => 'make an image, a sound or a video for the person through the matching agent (set "kind" to image, audio or video, and write "prompt" as a full, self-contained description). Set "app" to the appointment it belongs to when you know it; leave "app" out and the media waits in the Camera pool to be filed' },
	{ name => 'create', args => { app => 'lunch', title => 'lunch with Mom', when => 'in 3 hours', type => 'start', duration => '20 minutes' }, example => '{"action":"create","app":"meditate","title":"evening sit","when":"in 3 hours","type":"start","duration":"20 minutes"}',
	  desc => 'propose a new appointment; it is staged for the person to promote, never written straight in. Set "type" to "start", "record" or "command" for something the alarm will fire at that time (a future start begins the activity; record starts a recording; command runs the app\'s configured command), or leave it "stop" for a plain one-off log entry. Set "duration" to how long it lasts ("20 minutes", "1h") only when they say - give a plain positive length; time is an accrual, so the tree stores it as a negative offset itself' },
	{ name => 'schedule', args => { token => 'the token from the question', text => 'the clarified schedule' }, example => '{"action":"schedule","token":"abc123","text":"every third Saturday of the month for a year"}',
	  desc => 'finish a schedule that could not be read yet: pass the token from the question and the person\'s clarified words. It writes the repeat appointments or bills and says how many. Use it after asking what was unclear; the token names the appointment or bill already waiting.' },
	{ name => 'promote', args => { }, example => '{"action":"promote"}',
	  desc => 'save the appointment you just staged, after the person says yes' },
	{ name => 'discard', args => { }, example => '{"action":"discard"}',
	  desc => 'throw away the appointment you just staged, if the person declines' },
	{ name => 'update', args => { app => 'email test', title => '', delay => '5 minutes', when => '', duration => '10 minutes', notes => '' }, example => '{"action":"update","app":"email test","delay":"5 minutes"}',
	  desc => 'change an appointment that already exists, named by "app" (add "title" when you know it). "delay" pushes it later by the length the person said ("5 minutes", "1 hour"); "when" moves it to a named moment instead; "duration" sets how long it lasts; "notes" replaces the note. Give only the fields that change. It is staged as a proposal for the person to confirm, never written straight in' },
	{ name => 'undo', args => { }, example => '{"action":"undo"}',
	  desc => 'undo the change you last made to an appointment, putting it back the way it was' },
	{ name => 'alias', args => { alias => 'zzz', target => 'sleep' }, example => '{"action":"alias","alias":"zzz","target":"sleep"}',
	  desc => 'remember a word the person uses for a thing - "aka", "call it", "zzz means sleep". Give the alias as they said it and the target in their words; the target is resolved like any other name, and an ambiguous target is asked about, never guessed' },
	{ name => 'unalias', args => { alias => 'zzz' }, example => '{"action":"unalias","alias":"zzz"}',
	  desc => 'forget a word the person taught you' },
	{ name => 'stop', args => { app => 'email test', when => 'in 10 minutes', title => '' }, example => '{"action":"stop","app":"email test"}',
	  desc => 'stop what the app has running. With no "when" it stops now; give "when" as a length from now ("in 10 minutes") or a clock time ("at 5pm") to stop it then. It stops at once, not staged - say briefly what you stopped' },
	{ name => 'delete', args => { app => 'email test', title => '', when => 'yesterday at 3:30pm', which => 'upcoming' }, example => '{"action":"delete","app":"email test","which":"upcoming"}',
	  desc => 'delete one of the app\'s appointments. Choose it with "which" - "upcoming" (the next one) or "last" (the most recent past one) - or give "when" as a named moment ("yesterday around 3:30pm", "a week from now") to pick the closest one. Add "title" to match the note. It is staged as a proposal for the person to confirm, never deleted straight away' },
);

# Every appointment type the Guide's create may stage, so the model is told the
# closed set rather than inventing one. The alarm clock treats start/record/
# command as things to fire when their time comes.
our @guide_create_types = qw/stop start record command/;

# ---- the app-action bridge -------------------------------------------------
# One validated tool (`app`) can call an app's own declared route. The entries
# below are the whole vocabulary: a "do" not named here cannot run, and a route
# not named here cannot be reached. The help topic supplies the words and the
# briefing; this table supplies only what voice can actually do with them.
#
# kind "read" is a GET that never writes; kind "write" is a POST and waits for
# the person's confirmation unless the Confirmation Requirement is off. The
# route action must return JSON: the bridge speaks a summary, never HTML.
our @app_actions = (
	{
		app => 'clock', do => 'timers', kind => 'read',
		method => 'get', route => '/manager/clock/state',
		params => {},
		desc => 'read the running timers and the next alarm',
		speech => sub {
			my ($d) = @_;
			my @running = grep { (($_->{'state'} // '') eq 'running') } @{ $d->{'timers'} || [] };
			my @alarms = grep { ($_->{'enabled'} // 0) && ($_->{'next_at'} // 0) } @{ $d->{'alarms'} || [] };
			my @bits;
			push @bits, scalar(@running) . ' timer' . (@running == 1 ? '' : 's') . ' running' if @running;
			if (@alarms) {
				my $a = $alarms[0];
				my @lt = localtime(int($a->{'next_at'} / 1000));
				my $label = ($a->{'label'} // '') ne '' ? ('"' . $a->{'label'} . '" at ') : '';
				push @bits, 'the next alarm is ' . $label . sprintf('%d:%02d %s', ($lt[2] % 12) || 12, $lt[1], $lt[2] >= 12 ? 'pm' : 'am');
			}
			return @bits ? (ucfirst(join '; ', @bits) . '.') : 'No timers are running and no alarm is set.';
		},
	},
	{
		app => 'email', do => 'count', kind => 'read',
		method => 'get', route => '/manager/mail/email/list',
		params => { folder => 'inbox, starred, drafts, sent, outbox, archive, trash or contacts' },
		desc => 'count the threads in one mail folder',
		speech => sub {
			my ($d, $p) = @_;
			my $folder = ($p->{'folder'} // '') ne '' ? $p->{'folder'} : 'inbox';
			my $n = 0 + ($d->{'total'} // 0);
			return 'The ' . $folder . ' holds ' . $n . ' thread' . ($n == 1 ? '' : 's') . '.';
		},
	},
	{
		app => 'market', do => 'add_item', kind => 'write',
		method => 'post', route => '/manager/market/item_add',
		params => {
			text => 'the item to add (required)',
			list => 'the list name, optional',
			vendor => 'the shop, optional',
		},
		required => { text => 'the item to add' },
		confirm => 'I can add that to the shopping list. Confirm it and I will.',
		desc => 'add an item to the shopping list',
		speech => sub {
			my ($d) = @_;
			my $text = ($d->{'item'} && ($d->{'item'}->{'text'} // '') ne '') ? $d->{'item'}->{'text'} : 'the item';
			return 'Added ' . $text . ' to the shopping list.';
		},
	},
	{
		app => 'store', do => 'find', kind => 'read',
		method => 'get', route => '/manager/store/register/items',
		params => { search => 'the item or word to look for' },
		required => { search => 'what to look for' },
		desc => 'find items and prices in the Store',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $p = (ref $_[1] eq 'HASH') ? $_[1] : {};
			my $items = (ref $d->{'items'} eq 'ARRAY') ? $d->{'items'} : [];
			my $n = scalar @{$items};
			unless ($n) {
				my $q = ($p->{'search'} // '');
				return $q ne '' ? 'Nothing in the Store matches "' . $q . '".' : 'Nothing in the Store matches that.';
			}
			my @named;
			foreach my $it ( @{$items} ) {
				last if @named >= 3;
				next unless ref $it eq 'HASH';
				my $name = ($it->{'name'} // '') ne '' ? $it->{'name'} : 'an item';
				my $price = ($it->{'price'} // '') ne '' ? ' at ' . $it->{'price'} : '';
				push @named, $name . $price;
			}
			return 'I found ' . $n . ' item' . ($n == 1 ? '' : 's')
				. (@named ? ': ' . join(', ', @named) : '') . '.';
		},
	},
	{
		app => 'store', do => 'orders', kind => 'read',
		method => 'get', route => '/manager/store/register/state',
		params => {},
		desc => 'read the open register orders',
		speech => sub {
			my $d = (ref $_[0] eq 'HASH') ? $_[0] : {};
			my $orders = (ref $d->{'orders'} eq 'ARRAY') ? $d->{'orders'} : [];
			my $n = scalar @{$orders};
			return 'The register is clear; no orders are open.' unless $n;
			my ($total, $priced) = (0, 0);
			foreach my $o ( @{$orders} ) {
				next unless ref $o eq 'HASH';
				my $t = $o->{'totals'};
				next unless ref $t eq 'HASH';
				my $amount = $t->{'total'};
				next unless defined $amount && $amount =~ /^\s*-?\d+(?:\.\d+)?\s*$/;
				$total += $amount;
				$priced++;
			}
			my $say = $n . ' order' . ($n == 1 ? ' is' : 's are') . ' open';
			$say .= ' and ' . ($n == 1 ? 'its total is ' : 'they total ') . sprintf('%.2f', $total) if $priced;
			return ucfirst($say) . '.';
		},
	},
);

# The Coding agent's tools: a closed vocabulary the model may pick from, one
# action per turn, exactly like the Guide's. Unlike the Guide, these run on the
# server (files, git, the release routine) so a spoken or typed request can
# change the code and ship it - the self-healing half of the pair.
our @coding_tools = (
	{ name => 'list', example => '{"action":"list","path":"lib"}',
		desc => 'list the files in a folder inside the jawnos repo (a path relative to the repo root; "." is the root)' },
	{ name => 'read', example => '{"action":"read","path":"help.pl","offset":10,"limit":40}',
		desc => 'read a file inside the repo, or one range of it with "offset" (first line, 1-based) and "limit" (line count, capped at 200); a range is what a symbol needs, not the whole file' },
	{ name => 'write', example => '{"action":"write","path":"help.pl","content":"...the whole file..."}',
		desc => 'write a whole file inside the repo, replacing it; give the complete new contents, not a diff' },
	{ name => 'patch', example => '{"action":"patch","path":"help.pl","old":"the exact text","new":"its replacement"}',
		desc => 'replace one exact block of text in a file inside the repo; "old" must appear once (include more context if it is ambiguous, or set "all":true for every match). The answer names the line changed, and the file is checked after the edit' },
	{ name => 'run', example => '{"action":"run","command":"perl -c perl/Manager.pl"}',
		desc => 'run one checked command in the repo: perl -c <file>, perl scripts/<file>, prove, or a read-only git command (status, diff, log). Anything else is refused' },
	{ name => 'agent', example => '{"action":"agent","tasks":[{"task":"where is the sync cursor written?","scope":"read"},{"task":"read the retry policy","scope":"read"}]}',
		desc => 'hand self-contained investigations or scoped edits to subagents: "task" runs one, or "tasks" (a list of objects with "task", and optional "scope" and "paths") runs several at the same time. "scope":"read" (the default) lets a subagent list, read and run checks anywhere; "scope":"write" also needs "paths", a list of repo paths it may write within, and two write-scope tasks in one batch may not overlap. A subagent cannot ship: it never bumps, commits, pushes or restarts, and it cannot ask for another agent' },
	{ name => 'bump', example => '{"action":"bump"}',
		desc => 'bump the patch version in ./VERSION (the normal step before a commit)' },
	{ name => 'commit', example => '{"action":"commit","message":"fix the help header"}',
		desc => 'stage every change and commit it as "v<version> - <message>"' },
	{ name => 'push', example => '{"action":"push"}',
		desc => 'push the commits to GitHub (origin)' },
	{ name => 'restart', example => '{"action":"restart"}',
		desc => 'restart the jawn tree so the changed Perl and JS go live' },
	{ name => 'learn', example => '{"action":"learn","name":"house_lights_off","desc":"turn the house lights off","primitive":"set_setting","params":{"app":"house","setting":"toggle","value":"off"}}',
		desc => 'teach the Guide a new runtime command: a name, a description, and a primitive (say, open_app, set_setting, run_command, toggle, stage, find, play_music) with its params; saved to the shared setting so every machine learns it' },
	{ name => 'say', example => '{"action":"say","text":"..."}',
		desc => 'answer or report in words, then stop' },
	{ name => 'done', example => '{"action":"done","text":"..."}',
		desc => 'you have finished; say briefly what changed (and the new version)' },
);
