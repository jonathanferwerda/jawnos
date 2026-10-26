CREATE TABLE "appointments" (
app VARCHAR(500),
timestamp VARCHAR(25),
data LONGTEXT,
type VARCHAR(500),
account VARCHAR(500),
amount VARCHAR(25),
unit VARCHAR(250),
duration VARCHAR(500),
status VARCHAR(100),
notes LONGTEXT,
start_notes LONGTEXT,
end_notes LONGTEXT,
vendor VARCHAR(500),
tax VARCHAR(500),
quantity VARCHAR(255),
total VARCHAR(500),
item LONGTEXT,
server_time VARCHAR(500),
file LONGTEXT,
device VARCHAR(255)
, project VARCHAR(500), pos VARCHAR(25), club VARCHAR(500), warranty varchar(500), source VARCHAR(25), formulas LONGTEXT, position VARCHAR(25), toggle bool, uuid VARCHAR(255) unique, ticket_uuid VARCHAR(255) unique, browser_tab_id VARCHAR(500), seen VARCHAR(5), model LONGTEXT, option LONGTEXT, movement VARCHAR(25), aux VARCHAR(25), aux_description VARCHAR(500), state VARCHAR(25), has_tax VARCHAR(5), has_totes VARCHAR(5), ost VARCHAR(25), balance VARCHAR(25), measures LONGTEXT, manufacturer LONGTEXT, encryption_standard VARCHAR(25), options LONGTEXT, source_uuid VARCHAR(255), currency VARCHAR(10), stop_seen VARCHAR(5), stop_timestamp VARCHAR(255), duties LONGTEXT, next_duty VARCHAR(255), subtype VARCHAR(255), app_uuid VARCHAR(255));
CREATE TABLE "backups" (
timestamp LONGTEXT,
server_time LONGTEXT,
signatorial LONGTEXT,
destination LONGTEXT
, size VARCHAR(255), reason VARCHAR(25), warranty varchar(25), uuid VARCHAR(255) unique, columns recipient VARCHAR(500), recipient VARCHAR(500), ost VARCHAR(25), enc_file VARCHAR(255));
CREATE TABLE "cache" (
			timestamp VARCHAR(255),
			server_time VARCHAR(255),
			app LONGTEXT,
			context VARCHAR(255)
		, warranty VARCHAR(25), subcontext VARCHAR(25), device VARCHAR(10), uuid VARCHAR(255) unique, ost VARCHAR(25), data BLOB);
CREATE TABLE "crypto_address" (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			app VARCHAR(255),
			asset VARCHAR(25),
			network VARCHAR(255),
			address VARCHAR(255) unique,
			derivation VARCHAR(25),
			addr_index INTEGER,
			path VARCHAR(255),
			invoice_uuid VARCHAR(255),
			issued_at VARCHAR(25));
CREATE INDEX idx1_crypto_address on crypto_address (app, addr_index);
CREATE INDEX idx2_crypto_address on crypto_address (invoice_uuid);
CREATE TABLE "continent" (
latitude VARCHAR(25),
longitude VARCHAR(25),
accuracy VARCHAR(5),
timestamp VARCHAR(25),
operator VARCHAR(255),
operator_door LONGTEXT,
server_time VARCHAR(500), uuid VARCHAR(255) unique, type VARCHAR(25), scope VARCHAR(25), app VARCHAR(500), warranty VARCHAR(25), ost VARCHAR(25), signatorial VARCHAR(500));
CREATE TABLE "devices" (
protocol VARCHAR(25),
timestamp VARCHAR(50),
hostname VARCHAR(255),
port VARCHAR(25)
, uname VARCHAR(1000), address VARCHAR(255), mac VARCHAR(500), name VARCHAR(255), ws LONGTEXT, server_time VARCHAR(25), president VARCHAR(500), manager_password VARCHAR(500), uuid VARCHAR(255) unique, domain VARCHAR(255), room VARCHAR(255), ost VARCHAR(25), chip_ids LONGTEXT);
CREATE TABLE "magazine" (
			uuid VARCHAR(255) unique,
			timestamp VARCHAR(255),
			server_time VARCHAR(255),
			category VARCHAR(25),
			content LONGTEXT,
			text_colour VARCHAR(10),
			background_colour VARCHAR(10),
			manager_file VARCHAR(500),
			status VARCHAR(25),
			title VARCHAR(255)
		, warranty VARCHAR(255), image LONGTEXT, teaser VARCHAR(100), ost VARCHAR(25));
CREATE TABLE "mailbox" (
			uuid VARCHAR(255) unique,
			timestamp VARCHAR(255),
			server_time VARCHAR(255),
			body LONGTEXT,
			app VARCHAR(2000),
			manager_file VARCHAR(500),
			status VARCHAR(25)
		, project VARCHAR(255), club VARCHAR(255), team VARCHAR(255), community VARCHAR(255), contact VARCHAR(255), account VARCHAR(255), person VARCHAR(255), institution VARCHAR(255), government VARCHAR(255), corporation VARCHAR(255), place VARCHAR(255), vendor VARCHAR(255), event VARCHAR(255), ost VARCHAR(25), phone VARCHAR(25), email VARCHAR(255), subject VARCHAR(1000), attachments LONGTEXT, from_email VARCHAR(255), file LONGTEXT, sender VARCHAR(25), email_server VARCHAR(255), conversation_uuid VARCHAR(255), cc VARCHAR(1000), bcc VARCHAR(1000), seen VARCHAR(10), starred VARCHAR(10), thread VARCHAR(255), message_id VARCHAR(255), in_reply_to VARCHAR(255), thread_refs LONGTEXT);
CREATE TABLE "model" (
			app VARCHAR(500),
			name VARCHAR(500),
			price VARCHAR(25),
			characteristics LONGTEXT,
			timestamp VARCHAR(25),
			server_time VARCHAR(25),
			uuid VARCHAR(255) unique,
			files LONGTEXT
		, cost VARCHAR(25), description VARCHAR(2000), discount VARCHAR(25), markup VARCHAR(25), ost VARCHAR(25), manufacturer VARCHAR(255), def VARCHAR(10), quantity VARCHAR(10), unit VARCHAR(10), save_app VARCHAR(10), file LONGTEXT, delay_start VARCHAR(255), delay_stop VARCHAR(255), def_month VARCHAR(500), def_day VARCHAR(500), def_hour VARCHAR(500), def_wday VARCHAR(500));
CREATE TABLE "neighbour_link" (
			uuid VARCHAR(255) unique,
			initiator VARCHAR(255),
			connections LONGTEXT,
			server_time VARCHAR(255),
			initiated VARCHAR(255),
			status VARCHAR(25)
		, ost VARCHAR(25), credential LONGTEXT, name VARCHAR(255));
CREATE TABLE "notes" (
			uuid VARCHAR(255) unique,
			timestamp VARCHAR(255),
			server_time VARCHAR(255),
			app VARCHAR(255),
			device VARCHAR(255),
			text LONGTEXT,
			ost VARCHAR(25));
CREATE TABLE "notifications" (
			timestamp VARCHAR(255),
			message VARCHAR(500),
			title VARCHAR(255),
			tag VARCHAR(500),
			key VARCHAR(500),
			id INT,
			image VARCHAR(500)
		, uuid VARCHAR(255) unique, server_time VARCHAR(50), ost VARCHAR(25), role VARCHAR(100), app VARCHAR(255));
CREATE TABLE "option" (
			app VARCHAR(500),
			name VARCHAR(500),
			price VARCHAR(25),
			characteristics LONGTEXT,
			timestamp VARCHAR(25),
			server_time VARCHAR(25),
			uuid VARCHAR(255) unique,
			files LONGTEXT
		, cost VARCHAR(25), description VARCHAR(2000), discount VARCHAR(25), markup VARCHAR(25), ost VARCHAR(25), manufacturer VARCHAR(255), def VARCHAR(10), quantity VARCHAR(10), unit VARCHAR(10), save_app VARCHAR(10), file LONGTEXT, delay_start VARCHAR(255), delay_stop VARCHAR(255), def_month VARCHAR(500), def_day VARCHAR(500), def_hour VARCHAR(500), def_wday VARCHAR(500));
CREATE TABLE "option_category" (
			supplier VARCHAR(500),
			app VARCHAR(500),
			name VARCHAR(500),
			multi VARCHAR(5),
			timestamp VARCHAR(25),
			server_time VARCHAR(25),
			uuid VARCHAR(255) unique,
			characteristics VARCHAR(500)
		, price VARCHAR(25), category VARCHAR(255), cost VARCHAR(25), description VARCHAR(2000), discount VARCHAR(25), markup VARCHAR(25), ost VARCHAR(25), manufacturer VARCHAR(255), def VARCHAR(10), quantity VARCHAR(10), unit VARCHAR(10), save_app VARCHAR(10), file LONGTEXT, delay_start VARCHAR(255), delay_stop VARCHAR(255), def_month VARCHAR(500), def_day VARCHAR(500), def_hour VARCHAR(500), def_wday VARCHAR(500));
CREATE TABLE "remote_machines" (
			uuid VARCHAR(255) unique,
			ip VARCHAR(25),
			mac VARCHAR(25),
			timestamp VARCHAR(25),
			server_time VARCHAR(25),
			connected VARCHAR(25),
			status VARCHAR(25),
			log LONGTEXT
		, port VARCHAR(19), buttons VARCHAR(500), manager VARCHAR(255), data LONGTEXT, signatorial VARCHAR(500), cookie LONGTEXT(500), connection VARCHAR(10), nic VARCHAR(25), deletions LONGTEXT, ws_port VARCHAR(10), fqdn VARCHAR(255), ws_auth VARCHAR(500), manager_file VARCHAR(255), additions LONGTEXT, edits LONGTEXT, device VARCHAR(20), ost VARCHAR(25), hostname VARCHAR(255), tunnel VARCHAR(25), mirrors LONGTEXT, network LONGTEXT, pseudonyms LONGTEXT, dock_port VARCHAR(15), archive_dir LONGTEXT, archive LONGTEXT, version VARCHAR(25), sync_cursor VARCHAR(50), pubkey LONGTEXT, privilege VARCHAR(25), grant_scope VARCHAR(25), grant_expires VARCHAR(25), crest_uuid VARCHAR(255), crest_cosig LONGTEXT);
CREATE TABLE IF NOT EXISTS routers (
	uuid VARCHAR(255) unique,
	ip VARCHAR(64),
	mac VARCHAR(64),
	nic VARCHAR(64),
	name VARCHAR(255),
	model VARCHAR(255),
	manager VARCHAR(255),
	last_seen VARCHAR(25),
	timestamp VARCHAR(25),
	server_time VARCHAR(25),
	ost VARCHAR(25)
);
CREATE TABLE IF NOT EXISTS paired_devices (
	uuid VARCHAR(255) unique,
	name VARCHAR(255),
	pubkey LONGTEXT,
	bio_pubkey LONGTEXT,
	privilege VARCHAR(25),
	status VARCHAR(25),
	timestamp VARCHAR(25),
	server_time VARCHAR(25),
	ost VARCHAR(25),
	last_seen VARCHAR(25),
	agent VARCHAR(500),
	kind VARCHAR(25),
	person_uuid VARCHAR(255),
	share_pubkey VARCHAR(255)
);
CREATE TABLE IF NOT EXISTS people (
	uuid VARCHAR(255) unique,
	name VARCHAR(255),
	privilege VARCHAR(25),
	status VARCHAR(25),
	created VARCHAR(255),
	ost VARCHAR(25),
	server_time VARCHAR(255),
	app VARCHAR(255)
);
CREATE TABLE IF NOT EXISTS device_requests (
	uuid VARCHAR(255) unique,
	name VARCHAR(255),
	pubkey LONGTEXT,
	agent VARCHAR(500),
	code VARCHAR(25),
	status VARCHAR(25),
	device_uuid VARCHAR(255),
	remote_address VARCHAR(255),
	timestamp VARCHAR(25),
	server_time VARCHAR(25),
	ost VARCHAR(25)
);
CREATE TABLE IF NOT EXISTS house_key_shares (
	uuid VARCHAR(255) unique,
	set_id VARCHAR(255),
	share_index INTEGER,
	holder_person VARCHAR(255),
	holder_device VARCHAR(255),
	alg VARCHAR(25),
	wrapped LONGTEXT,
	status VARCHAR(25),
	created VARCHAR(255),
	server_time VARCHAR(255),
	ost VARCHAR(25)
);
CREATE TABLE IF NOT EXISTS house_key_share_requests (
	uuid VARCHAR(255) unique,
	code VARCHAR(25),
	asker_pubkey VARCHAR(255),
	name VARCHAR(255),
	need INTEGER,
	available INTEGER,
	set_id VARCHAR(255),
	status VARCHAR(25),
	created VARCHAR(255),
	server_time VARCHAR(255),
	ost VARCHAR(25)
);
CREATE TABLE IF NOT EXISTS house_key_share_releases (
	uuid VARCHAR(255) unique,
	request_uuid VARCHAR(255),
	set_id VARCHAR(255),
	share_index INTEGER,
	holder_device VARCHAR(255),
	wrapped LONGTEXT,
	created VARCHAR(255),
	server_time VARCHAR(255),
	ost VARCHAR(25)
);
CREATE TABLE "security" (
level VARCHAR(255),
credential VARCHAR(255),
server_time VARCHAR(255), 
timestamp VARCHAR(255),
database VARCHAR(255)
, uuid VARCHAR(255) unique, ost VARCHAR(25));
CREATE TABLE "settings" (
setting VARCHAR(50),
value VARCHAR(50),
timestamp VARCHAR(25),
id INT AUTO_INCREMENT PRIMARY KEY,
app VARCHAR(50),
server_time VARCHAR(500),
device VARCHAR(255)
, browser_tab_id VARCHAR(255), uuid VARCHAR(255) unique, ost VARCHAR(25), subsetting VARCHAR(255));
CREATE TABLE "subcategory" (
			supplier VARCHAR(500),
			app VARCHAR(500),
			name VARCHAR(500),
			multi VARCHAR(5),
			price VARCHAR(25),
			timestamp VARCHAR(25),
			server_time VARCHAR(25),
			uuid VARCHAR(255) unique,
			characteristics VARCHAR(500)
		, category VARCHAR(255), cost VARCHAR(25), ost VARCHAR(25), description VARCHAR(2000), discount VARCHAR(25), markup VARCHAR(25), manufacturer VARCHAR(255), def VARCHAR(10), quantity VARCHAR(10), unit VARCHAR(10), save_app VARCHAR(10), file LONGTEXT, delay_start VARCHAR(255), delay_stop VARCHAR(255), def_month VARCHAR(500), def_day VARCHAR(500), def_hour VARCHAR(500), def_wday VARCHAR(500));
CREATE TABLE "tickets" (
			uuid VARCHAR(255) unique,
			warranty VARCHAR(25),
			name VARCHAR(255),
			projects LONGTEXT,
			accounts LONGTEXT			
		, timestamp VARCHAR(25), server_time VARCHAR(25), url VARCHAR(500), image LONGTEXT, privilege VARCHAR(10), status VARCHAR(25), verification VARCHAR(1000), duration VARCHAR(1000), app VARCHAR(1000), password VARCHAR(255), browser_tab_id VARCHAR(255), project VARCHAR(255), port VARCHAR(10), ip VARCHAR(255), secret VARCHAR(500), nic VARCHAR(255), suds VARCHAR(500), debriefer LONGTEXT, approval_rating VARCHAR(500), information VARCHAR(2500), ost VARCHAR(25), access_log LONG_TEXT, person_uuid VARCHAR(255), peer_signatorial VARCHAR(255), crest_uuid VARCHAR(255));
CREATE TABLE "websites" (
url VARCHAR(500),
content LONGTEXT,
illegal_content LONGTEXT,
timestamp,
app VARCHAR(500),
internal_url VARCHAR(50), server_time VARCHAR(25), warranty VARCHAR(25), uuid VARCHAR(255) unique, ost VARCHAR(25));
CREATE TABLE "usage_sessions" (
	uuid VARCHAR(255) unique,
	device VARCHAR(255),
	kind VARCHAR(16),
	key_name VARCHAR(500),
	started_at VARCHAR(25),
	ended_at VARCHAR(25),
	idle_ms VARCHAR(25),
	source VARCHAR(25),
	hostname VARCHAR(500),
	title VARCHAR(1000),
	url VARCHAR(2000),
	server_time VARCHAR(25),
	ost VARCHAR(25));
CREATE TABLE "websocket_messages" (
timestamp VARCHAR(255),
server_time VARCHAR(255),
message LONGTEXT,
destination VARCHAR(255),
origin VARCHAR(255),
status VARCHAR(25)
, app VARCHAR(5000), environment VARCHAR(25), sent_count VARCHAR(25), uuid VARCHAR(255) unique, tally INT, ost VARCHAR(25), patience VARCHAR(5));
CREATE TABLE "websockets" (
timestamp VARCHAR(255),
server_time VARCHAR(255),
message LONGTEXT,
app LONGTEXT,
uuid VARCHAR(255) unique
, connection_id VARCHAR(255), browser_tab_id VARCHAR(255), browser_tab VARCHAR(255), hostname VARCHAR(500), connected VARCHAR(25), user_agent LONGTEXT, local_address VARCHAR(25), remote_address VARCHAR(25), type VARCHAR(25), windows LONGTEXT, room VARCHAR(255), db VARCHAR(255), music_data LONGTEXT, jp_data LONGTEXT, random_string VARCHAR(500), warranty VARCHAR(25), href VARCHAR(500), pathname VARCHAR(500), cookie LONGTEXT, ost VARCHAR(25), ticket_uuid VARCHAR(255), revision VARCHAR(255));
CREATE TABLE tunnels (
			server_time VARCHAR(255),
			ost VARCHAR(255),
			device VARCHAR(255),
			timestamp VARCHAR(255),
			ip VARCHAR(255),
			in_port VARCHAR(5),
			out_port VARCHAR(5),
			name VARCHAR(255),
			warranty VARCHAR(255),
			priority VARCHAR(5),
			status VARCHAR(25),
			process_id VARCHAR(10),
			signatorial VARCHAR(500),
			direction VARCHAR(7),
			uuid VARCHAR(50)
		, batch_uuid VARCHAR(255), domain VARCHAR(255), host VARCHAR(500), failures INT);
CREATE TABLE warehouse (
			timestamp VARCHAR(255),
			server_time VARCHAR(255),
			item VARCHAR(500),
			model LONGTEXT,
			options LONGTEXT,
			uuid VARCHAR(500),
			ost VARCHAR(255),
			device VARCHAR(100),
			quantity VARCHAR(25),
			unit VARCHAR(255),
			data LONGTEXT,
			serial_number VARCHAR(1000),
			batch_uuid VARCHAR(255),
			app_uuid VARCHAR(255)
		, place VARCHAR(500), type VARCHAR(25), project VARCHAR(255), account VARCHAR(255), warranty VARCHAR(25));
CREATE INDEX idx1_tunnels on tunnels (signatorial);
CREATE INDEX idx2_settings on settings (setting,device);
CREATE INDEX idx3_settings on settings (setting,value);
CREATE INDEX idx4_settings on settings (setting,device,value);
CREATE INDEX idx2_appts on appointments (app,timestamp);
CREATE INDEX idx7_appts on appointments (timestamp,seen);
CREATE INDEX idx8_appts on appointments (timestamp, stop_timestamp, seen, stop_seen);
CREATE INDEX idx9_appts on appointments (stop_timestamp,stop_seen);
CREATE INDEX idx10_appts on appointments (duties,next_duty);
CREATE INDEX idx11_appts on appointments (app,server_time,status);
CREATE INDEX idx1_ws on websockets (app,browser_tab_id);
CREATE INDEX idx3_ws on websockets (app,browser_tab_id,remote_address);
CREATE INDEX idx2_ws on websockets (browser_tab_id);
CREATE INDEX idx1_continent on continent (app);
CREATE INDEX idx2_continent on continent (app,uuid);
CREATE INDEX idx1_security on security (level);
CREATE INDEX idx2_security on security (level,server_time);
CREATE INDEX idx1_cache on cache (app,device,context,subcontext);
CREATE INDEX idx1_notes on notes (timestamp);
CREATE INDEX idx2_notes on notes (uuid);
CREATE INDEX idx1_backups on backups (signatorial,recipient);
CREATE INDEX idx1_mailbox on mailbox (contact);
CREATE INDEX idx2_mailbox on mailbox (community,club,team,project,account,person);
CREATE INDEX idx2_backups on backups (recipient,signatorial);
CREATE INDEX idx3_backups on backups (recipient,signatorial,ost,reason);
CREATE INDEX idx4_backups on backups (recipient,signatorial,reason);

CREATE TABLE IF NOT EXISTS staged_appointments (
	uuid VARCHAR(255) unique,
	staged_time VARCHAR(255),
	source VARCHAR(255),
	app VARCHAR(500),
	type VARCHAR(500),
	timestamp VARCHAR(25),
	title VARCHAR(500),
	notes LONGTEXT,
	data LONGTEXT,
	device VARCHAR(255),
	status VARCHAR(25),
	server_time VARCHAR(255),
	ost VARCHAR(25),
	duration VARCHAR(25),
	kind VARCHAR(25),
	target_uuid VARCHAR(255),
	changes LONGTEXT
);
CREATE INDEX IF NOT EXISTS idx1_staged on staged_appointments (status, staged_time);

-- The sync bookkeeping tables. Manager.pl also creates these as a migration,
-- but President.pl reads sync_jobs at boot, before Manager runs, so a fresh
-- database built from this schema (and the factory seed made from it) must
-- carry them or the first boot dies on "no such table: sync_jobs".
CREATE TABLE IF NOT EXISTS sync_log (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	server_time VARCHAR(255),
	signatorial VARCHAR(500),
	tbl VARCHAR(255),
	app VARCHAR(255),
	uuid VARCHAR(255),
	scope VARCHAR(255),
	ost VARCHAR(255),
	additional LONGTEXT
);
CREATE TABLE IF NOT EXISTS sync_cursors (
	signatorial VARCHAR(500) PRIMARY KEY,
	cursor VARCHAR(50)
);
CREATE TABLE IF NOT EXISTS sync_jobs (
	uuid VARCHAR(255) PRIMARY KEY,
	direction VARCHAR(25),
	peer VARCHAR(500),
	phase VARCHAR(255),
	current INTEGER,
	total INTEGER,
	state VARCHAR(25),
	note LONGTEXT,
	steps LONGTEXT,
	started VARCHAR(25),
	updated VARCHAR(25)
);
CREATE INDEX IF NOT EXISTS idx1_sync_jobs on sync_jobs (state, updated);
CREATE TABLE IF NOT EXISTS sync_snapshots (
	uuid VARCHAR(255) PRIMARY KEY,
	job VARCHAR(255),
	caller VARCHAR(500),
	state VARCHAR(25),
	archive_path VARCHAR(1000),
	result LONGTEXT,
	size VARCHAR(25),
	sha256 VARCHAR(100),
	error LONGTEXT,
	timestamp VARCHAR(25),
	server_time VARCHAR(25),
	updated VARCHAR(25),
	ost VARCHAR(25)
);
CREATE INDEX IF NOT EXISTS idx1_sync_snapshots on sync_snapshots (state, updated);
