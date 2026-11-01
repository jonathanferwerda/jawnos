package subs;

# Migrations half of the domain layer: functions subroutines.pl calls that used
# to live in Manager.pl. Same package (subs) so every call site and the
# Manager:: aliases keep working; the Loader in lib/JawnOS/Domain/Loader.pm
# requires this file on the first call that needs it.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::JSON qw(decode_json encode_json);

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

sub update_database($data) {
	&subs::cache_delete({ app => 'me', context => 'pseudonyms' });
	my $commands = [
		# Watch-only receiving addresses: one row per invoice, public data only.
		# An address is never reused, and the unique index is what makes two
		# machines that allocated the same index while apart fall through to the
		# next one instead of sharing an address.
		'create table if not exists crypto_address (
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
			issued_at VARCHAR(25)
		)',
		'create index if not exists idx1_crypto_address on crypto_address (app, addr_index)',
		'create index if not exists idx2_crypto_address on crypto_address (invoice_uuid)',
		# Double-entry accounting: a chart of accounts and the journal that posts
		# to it. Both are derived from the money ledger, so each machine builds its
		# own (they stay out of the sync table list in gb.pl); the entries are
		# keyed by their source row so a rebuild is deterministic.
		'create table if not exists ledger_accounts (
			uuid VARCHAR(255) unique,
			code VARCHAR(20) unique,
			name VARCHAR(255),
			type VARCHAR(25),
			normal VARCHAR(10),
			app VARCHAR(500),
			parent VARCHAR(20),
			active VARCHAR(10),
			server_time VARCHAR(30),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_ledger_accounts on ledger_accounts (app)',
		'create table if not exists journal (
			uuid VARCHAR(90) unique,
			entry_uuid VARCHAR(90),
			timestamp VARCHAR(25),
			account_code VARCHAR(20),
			debit VARCHAR(30),
			credit VARCHAR(30),
			currency VARCHAR(20),
			memo VARCHAR(500),
			source_uuid VARCHAR(60),
			source_kind VARCHAR(25),
			app VARCHAR(500),
			account VARCHAR(500),
			server_time VARCHAR(30),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_journal_source on journal (source_uuid)',
		'create index if not exists idx2_journal_account on journal (account_code)',
		'create index if not exists idx3_journal_entry on journal (entry_uuid)',
		# People: a person is the identity, a device is how they carry it.
		'create table if not exists people (
			uuid VARCHAR(255) unique,
			name VARCHAR(255),
			privilege VARCHAR(25),
			status VARCHAR(25),
			created VARCHAR(255),
			ost VARCHAR(25),
			server_time VARCHAR(255)
		)',
		'create index if not exists idx1_people on people (uuid)',
		# a person construct (settings pos/mab = person) is the social person;
		# `app` links the people row to that settings app so the People window
		# and the Relational window cannot drift apart
		'alter table people add column app VARCHAR(255)',
		'create index if not exists idx2_people on people (app)',
		'alter table tickets add column person_uuid VARCHAR(255)',
		'alter table tickets add column peer_signatorial VARCHAR(255)',
		# a request may carry the crest of the house asking; the desk reads it
		# beside the known contacts, never as a grant
		'alter table tickets add column crest_uuid VARCHAR(255)',
		'alter table paired_devices add column person_uuid VARCHAR(255)',
		# A device can hold one wrapped Shamir share. The key is an X25519 key the
		# device generates for this alone (its login key may be signing-only); the
		# server wraps the share to it and never sees the share in the clear.
		'alter table paired_devices add column share_pubkey VARCHAR(255)',
		'create table if not exists house_key_shares (
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
		)',
		'create index if not exists idx1_house_key_shares on house_key_shares (set_id)',
		'create index if not exists idx2_house_key_shares on house_key_shares (holder_device)',
		# A machine with no vault asks for shares: only its ephemeral public key
		# is stored, and the holders answer with blobs the server cannot open.
		'create table if not exists house_key_share_requests (
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
		)',
		'create table if not exists house_key_share_releases (
			uuid VARCHAR(255) unique,
			request_uuid VARCHAR(255),
			set_id VARCHAR(255),
			share_index INTEGER,
			holder_device VARCHAR(255),
			wrapped LONGTEXT,
			created VARCHAR(255),
			server_time VARCHAR(255),
			ost VARCHAR(25)
		)',
		# A gateway is not a JawnOS peer: it has no manager and no session.
		# Keeping it in its own table lets the Dev panel show it after the
		# machine has left that network, with the last time it answered.
		'create table if not exists routers (
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
		)',
		'create index if not exists idx1_routers on routers (ip)',
		# Notes are their own store now, not appointments: one plain row per note.
		# The server_time column is what puts it on the generic peer sync and backup,
		# so a note still reaches every machine.
		'CREATE TABLE IF NOT EXISTS notes (uuid VARCHAR(255) unique, timestamp VARCHAR(255), server_time VARCHAR(255), app VARCHAR(255), device VARCHAR(255), text LONGTEXT, ost VARCHAR(25))',
		'CREATE INDEX IF NOT EXISTS idx1_notes on notes (timestamp)',
		'CREATE INDEX IF NOT EXISTS idx2_notes on notes (uuid)',
		'alter table appointments add column subtype VARCHAR(255)',
		# A construct's identity is its stable uuid, not its name; the label beside
		# it can change and two houses can use the same label. Filled from the
		# canonical construct_uuid setting on every new row.
		'alter table appointments add column app_uuid VARCHAR(255)',
		# The details bar can turn off the plate's automatic stop for the session
		# that is running; an unset value means on, which is every older row.
		'alter table appointments add column autostop VARCHAR(10)',
		'alter table mailbox add column sender VARCHAR(25)',
		'alter table mailbox add column email_server VARCHAR(255)',
		# schema.sql has carried these two for a while, but the migration list
		# never added them to an older database. A peer sent the columns anyway and
		# every mailbox batch failed with "table mailbox has no column named file",
		# so the same 827 rows were pulled again on every tick.
		'alter table mailbox add column from_email VARCHAR(255)',
		'alter table mailbox add column file LONGTEXT',
		# a composed letter can carry carbon copies now: cc is shown and answered
		# (reply-all), bcc travels to the smtp transport only and is never sent to
		# anyone who can see the headers. seen is the read/unread flag the list uses.
		'alter table mailbox add column cc VARCHAR(1000)',
		'alter table mailbox add column bcc VARCHAR(1000)',
		'alter table mailbox add column seen VARCHAR(10)',
		# starred is the flag the list and a Starred view read; thread is a
		# conversation key (the subject without its Re:/Fwd: plus the other party),
		# so a thread shows as one row and opens as the whole exchange.
		'alter table mailbox add column starred VARCHAR(10)',
		'alter table mailbox add column thread VARCHAR(255)',
		# the message headers a proper thread is built from: a letter's own Message-ID,
		# what it answers (In-Reply-To) and the chain it belongs to (References). The
		# thread column then holds the chain's root id rather than a subject guess.
		'alter table mailbox add column message_id VARCHAR(255)',
		'alter table mailbox add column in_reply_to VARCHAR(255)',
		'alter table mailbox add column thread_refs LONGTEXT',
		'drop table firewall',
		# ssh credentials are gone: transports, deploy and backup are all
		# password-less http/websocket now.
		'alter table remote_machines drop column username',
		'alter table remote_machines drop column password',
		'create table if not exists tunnels (
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
		)',
		'alter table tunnels add column batch_uuid VARCHAR(255)',
		'alter table tunnels add column failures INT',
		'alter table tunnels add column domain VARCHAR(255)',
		'alter table remote_machines add column tunnel VARCHAR(25)',
		'alter table remote_machines drop column tunnels',
		'alter table tunnels add column host VARCHAR(500)',
		'alter table remote_machines drop column sync_log',
		'alter table remote_machines add column mirrors LONGTEXT',
		'alter table remote_machines add column network LONGTEXT',
		'alter table remote_machines add column pseudonyms LONGTEXT',
		'alter table remote_machines add column dock_port VARCHAR(15)',
		'alter table remote_machines add column archive LONGTEXT',
		'alter table remote_machines add column archive_dir VARCHAR(255)',
		'alter table remote_machines add column sync_cursor VARCHAR(50)',
		'alter table remote_machines add column version VARCHAR(25)',
		# the peer's cached Ollama model list, so Plat can offer models by the machine
		# they live on without waiting on the network (filled by ollama_models_sync)
		'alter table remote_machines add column ollama_models LONGTEXT',
		# the records watch's staging area: a finding the fixed appointment audit
		# produced (a sweep, a duplicate, an orphan, an impossible row) and the actions
		# proposed for it, waiting for a person to Apply. Machine-local - the rowids and
		# uuids name this machine's own rows - so the table sits in gb's forbidden
		# list and never rides the peer sync, exactly like staged_fixes.
		'create table if not exists staged_records (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			kind VARCHAR(25),
			app VARCHAR(500),
			signature VARCHAR(500),
			sample LONGTEXT,
			proposed LONGTEXT,
			status VARCHAR(25),
			model VARCHAR(255),
			note LONGTEXT,
			last_seen VARCHAR(255)
		)',
		'create index if not exists idx1_staged_records on staged_records (signature)',
		'create index if not exists idx2_staged_records on staged_records (status)',
		# the Guide writes here, not into appointments: a staged row is a proposal a
		# person can look over and promote (or drop) before it becomes real
		'create table if not exists staged_appointments (
			uuid VARCHAR(255) unique,
			staged_time VARCHAR(255),
			server_time VARCHAR(255),
			ost VARCHAR(25),
			source VARCHAR(255),
			app VARCHAR(500),
			type VARCHAR(500),
			timestamp VARCHAR(25),
			title VARCHAR(500),
			notes LONGTEXT,
			data LONGTEXT,
			duration VARCHAR(25),
			device VARCHAR(255),
			status VARCHAR(25)
		)',
		'alter table staged_appointments add column server_time VARCHAR(255)',
		'alter table staged_appointments add column ost VARCHAR(25)',
		# the Guide's create now carries a length ("lasts 5 minutes") as the negative
		# accrual the tree stores; a staged row keeps it so promote writes it on
		'alter table staged_appointments add column duration VARCHAR(25)',
		# a staged row may instead be a change to an appointment that already exists:
		# "kind" tells the two apart, "target_uuid" names the appointment the change
		# edits, and "changes" is the JSON of the fields to set on promote
		'alter table staged_appointments add column kind VARCHAR(25)',
		'alter table staged_appointments add column target_uuid VARCHAR(255)',
		'alter table staged_appointments add column changes LONGTEXT',
		'create index if not exists idx1_staged on staged_appointments (status, staged_time)',
		'create table if not exists sync_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			server_time VARCHAR(255),
			signatorial VARCHAR(500),
			tbl VARCHAR(255),
			app VARCHAR(255),
			uuid VARCHAR(255),
			scope VARCHAR(255),
			ost VARCHAR(255),
			additional LONGTEXT
		)',
		# every insert runs through db_insert, which stamps ost; a sync_log created
		# before this column existed failed every tombstone write with "table
		# sync_log has no column named ost". This adds it to those databases.
		'alter table sync_log add column ost VARCHAR(255)',
		'create table if not exists sync_cursors (
			signatorial VARCHAR(500) PRIMARY KEY,
			cursor VARCHAR(50)
		)',
		# One row per running or recently finished sync, for the yellow dot. It is
		# machine-local (it describes this machine's socket work), so the table is
		# in gb's forbidden list and never rides the peer sync or a backup.
		'create table if not exists sync_jobs (
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
		)',
		'create index if not exists idx1_sync_jobs on sync_jobs (state, updated)',
		# One row per remote snapshot this machine is building for a peer, so the
		# puller can ask how the build is going instead of holding the request
		# open for every minute of it. The result is the same reply backup_now
		# used to return synchronously. Machine-local (it names a temp file on
		# this disk and belongs to one caller), so it is in gb's forbidden list.
		'create table if not exists sync_snapshots (
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
		)',
		# The first build of this table shipped without ost; db_insert always
		# stamps it, so the row never landed. Add it for machines that already
		# created the table (the guard skips the alter once the column is there).
		'alter table sync_snapshots add column ost VARCHAR(25)',
		'create index if not exists idx1_sync_snapshots on sync_snapshots (state, updated)',
		# One row per Dev migration: this machine (the donor) asked a linked new
		# device to pull the whole house from here. Machine-local - it names this
		# donor's roster and its own serve job - so it is in gb's forbidden list.
		'create table if not exists migrations (
			uuid VARCHAR(255) PRIMARY KEY,
			device_signatorial VARCHAR(500),
			device_name VARCHAR(255),
			donor_signatorial VARCHAR(500),
			state VARCHAR(25),
			note LONGTEXT,
			started VARCHAR(25),
			updated VARCHAR(25),
			server_time VARCHAR(25),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_migrations on migrations (state, updated)',
		# The error watch's catch: an error seen in the running logs, and the fix
		# the Coding agent proposed for it, staged until a person applies it.
		# Machine-local (the rows name this repo's files), so the table sits in
		# gb's forbidden list and never rides the peer sync or a backup.
		'create table if not exists staged_fixes (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			source VARCHAR(25),
			signature VARCHAR(500),
			sample LONGTEXT,
			tally INT,
			status VARCHAR(25),
			model VARCHAR(255),
			summary LONGTEXT,
			files LONGTEXT,
			steps LONGTEXT,
			note LONGTEXT,
			last_seen VARCHAR(255)
		)',
		'create index if not exists idx1_staged_fixes on staged_fixes (signature)',
		'create index if not exists idx2_staged_fixes on staged_fixes (status)',
		# The house AI ledger: which machines can take AI work and were seen
		# recently (ai_house), which machine ran which job (ai_jobs), and each
		# machine's spend for the day (ai_budget). Unlike staged_fixes these carry
		# server_time and are not in gb's forbidden list, so they ride the ordinary
		# peer sync - the house cannot pay twice for one job and the day's budget is
		# one pot, not one per machine.
		'create table if not exists ai_house (
			uuid VARCHAR(255),
			machine VARCHAR(255) unique,
			has_model INT,
			seen VARCHAR(25),
			ost VARCHAR(255),
			server_time VARCHAR(255)
		)',
		'create table if not exists ai_jobs (
			uuid VARCHAR(255),
			job VARCHAR(255) unique,
			owner VARCHAR(255),
			at VARCHAR(25),
			state VARCHAR(25),
			ost VARCHAR(255),
			server_time VARCHAR(255)
		)',
		'create table if not exists ai_budget (
			uuid VARCHAR(255),
			machine VARCHAR(255),
			day VARCHAR(25),
			tokens INT,
			ost VARCHAR(255),
			server_time VARCHAR(255)
		)',
		'create unique index if not exists idx_ai_budget on ai_budget (machine, day)',
		# db_insert always writes uuid and ost, so a ledger table built before they
		# were added refuses its own inserts; add them for existing installs.
		'alter table ai_house add column uuid VARCHAR(255)',
		'alter table ai_house add column ost VARCHAR(255)',
		'alter table ai_jobs add column uuid VARCHAR(255)',
		'alter table ai_jobs add column ost VARCHAR(255)',
		'alter table ai_budget add column uuid VARCHAR(255)',
		'alter table ai_budget add column ost VARCHAR(255)',
		'alter table continent add column signatorial VARCHAR(500)',
		'alter table continent add column speed VARCHAR(25)',
		'alter table continent add column altitude VARCHAR(25)',
		'create table if not exists warehouse (
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
		)',
		'alter table mailbox add column conversation_uuid VARCHAR(255)',
		# The address tuple grew: institution, government, corporation, place,
		# vendor and event joined the social constructs, and an account stopped
		# being one. The account column stays so rows already filed under one keep
		# their record, but nothing addresses by it now. Backfill each new column
		# to its construct's default, or mail filed before this build would hide
		# behind NULL instead of joining the default dial.
		'alter table mailbox add column institution VARCHAR(255)',
		'alter table mailbox add column government VARCHAR(255)',
		'alter table mailbox add column corporation VARCHAR(255)',
		'alter table mailbox add column place VARCHAR(255)',
		'alter table mailbox add column vendor VARCHAR(255)',
		'alter table mailbox add column event VARCHAR(255)',
		"update mailbox set institution = 'house' where institution is null or institution = ''",
		"update mailbox set government = 'civic' where government is null or government = ''",
		"update mailbox set corporation = 'sole' where corporation is null or corporation = ''",
		"update mailbox set place = 'home' where place is null or place = ''",
		"update mailbox set vendor = 'market' where vendor is null or vendor = ''",
		"update mailbox set event = 'now' where event is null or event = ''",
		'alter table mailbox drop column artificial_intelligence',
		'alter table warehouse add column place VARCHAR(500)',
		'alter table warehouse add column type VARCHAR(25)',
		'alter table warehouse add column project VARCHAR(255)',
		'alter table warehouse add column account VARCHAR(255)',
		'alter table warehouse add column warranty VARCHAR(25)',
		# the warehouse is the ledger for money as well as stock now: a money move
		# carries the same fields the transaction did, so the budget can read it
		# without knowing it moved. kind names the three faces (stock/money/inventory)
		# so a row's purpose no longer rests on whether it happens to name an account.
		'alter table warehouse add column kind VARCHAR(25)',
		'alter table warehouse add column app VARCHAR(255)',
		'alter table warehouse add column movement VARCHAR(25)',
		'alter table warehouse add column vendor VARCHAR(255)',
		'alter table warehouse add column manufacturer VARCHAR(255)',
		'alter table warehouse add column currency VARCHAR(25)',
		'alter table warehouse add column amount VARCHAR(25)',
		'alter table warehouse add column tax VARCHAR(25)',
		'alter table warehouse add column aux VARCHAR(25)',
		'alter table warehouse add column total VARCHAR(25)',
		'alter table warehouse add column duration VARCHAR(25)',
		'alter table warehouse add column notes LONGTEXT',
		'alter table warehouse add column state VARCHAR(25)',
		'alter table warehouse add column source_uuid VARCHAR(255)',
		# The websocket connect writes the running code revision so a tab can reload
		# when it changes, but the column was never added to the table: every connect
		# failed with "table websockets has no column named revision", retried to the
		# driver's limit and left the tab unrecorded. Add it here for existing installs
		# (schema.sql carries it for a database built fresh).
		'alter table websockets add column revision VARCHAR(255)',
		# peers prove themselves with an Ed25519 signature now; the roster row
		# carries the public key (schema.sql has it for a fresh database).
		'alter table remote_machines add column pubkey LONGTEXT',
		# a grant is a lease, not a name: the scope a house may act at here, and
		# the epoch-ms instant it lapses. peer_allows reads them; an older row
		# with no scope keeps the trust it already had, so this is additive.
		# privilege is the relationship (citizen, peer, visitor, guest); scope is
		# what it may do here. The citizen's own machines are marked on the
		# remote_device_connect path, which only the shared house password opens.
		'alter table remote_machines add column privilege VARCHAR(25)',
		'alter table remote_machines add column grant_scope VARCHAR(25)',
		'alter table remote_machines add column grant_expires VARCHAR(25)',
		# A member machine cosigns the house crest with its peer key. crest_uuid is
		# the crest it backs and crest_cosig is its signed statement, so the roster
		# (and the card) can say which machines stand behind the crest.
		'alter table remote_machines add column crest_uuid VARCHAR(255)',
		'alter table remote_machines add column crest_cosig LONGTEXT',
		# paired devices: the browsers and phones a citizen has signed in once
		'create table if not exists paired_devices (uuid VARCHAR(255) unique, name VARCHAR(255), pubkey LONGTEXT, bio_pubkey LONGTEXT, privilege VARCHAR(25), status VARCHAR(25), timestamp VARCHAR(25), server_time VARCHAR(25), ost VARCHAR(25), last_seen VARCHAR(25), agent VARCHAR(500))',
		# a phone that has enrolled its biometric key: an EC P-256 key in the
		# Android Keystore that the OS releases only after the person authenticates
		'alter table paired_devices add column bio_pubkey LONGTEXT',
		# a readable origin for the Security page: phone, app, browser or the
		# desktop's WebKit windows
		'alter table paired_devices add column kind VARCHAR(25)',
		# device approvals: an ask that waits for a citizen, with the short code
		# shown on both screens (merges like the roster it becomes)
		'create table if not exists device_requests (uuid VARCHAR(255) unique, name VARCHAR(255), pubkey LONGTEXT, agent VARCHAR(500), code VARCHAR(25), status VARCHAR(25), device_uuid VARCHAR(255), remote_address VARCHAR(255), timestamp VARCHAR(25), server_time VARCHAR(25), ost VARCHAR(25))',
		'CREATE INDEX IF NOT EXISTS idx6_warehouse on warehouse (kind)',
		'CREATE INDEX idx1_tunnels on tunnels (signatorial)',
		'CREATE INDEX idx2_settings on settings (setting,device)',
		'CREATE INDEX idx3_settings on settings (setting,value)',
		'CREATE INDEX idx4_settings on settings (setting,device,value)',
		'CREATE INDEX idx2_appts on appointments (app,timestamp)',
		'CREATE INDEX idx7_appts on appointments (timestamp,seen)',
		'CREATE INDEX idx8_appts on appointments (timestamp, stop_timestamp, seen, stop_seen)',
		'CREATE INDEX idx9_appts on appointments (stop_timestamp,stop_seen)',
		'CREATE INDEX idx10_appts on appointments (duties,next_duty)',
		'CREATE INDEX idx11_appts on appointments (app,server_time,status)',
		'CREATE INDEX idx1_ws on websockets (app,browser_tab_id)',
		'CREATE INDEX idx3_ws on websockets (app,browser_tab_id,remote_address)',
		'CREATE INDEX idx2_ws on websockets (browser_tab_id)',
		'CREATE INDEX idx1_continent on continent (app)',
		'CREATE INDEX idx2_continent on continent (app,uuid)',
		# navigation_information asks continent for the current (type='temporary')
		# positions on every centre-view poll; with only (app) indexed that was a
		# full scan of the whole position history - 116k rows and growing - on
		# every tick. (type, signatorial, warranty) turns it into a lookup.
		'CREATE INDEX IF NOT EXISTS idx6_continent on continent (type, signatorial, warranty)',
		'CREATE INDEX idx1_security on security (level)',
		'CREATE INDEX idx2_security on security (level,server_time)',
		'CREATE INDEX idx1_cache on cache (app,device,context,subcontext)',
		'CREATE INDEX idx1_backups on backups (signatorial,recipient)',
		'CREATE INDEX idx1_mailbox on mailbox (contact)',
		'CREATE INDEX idx2_mailbox on mailbox (community,club,team,project,account,person)',
		'CREATE INDEX idx1_backups on backups (recipient,signatorial,ost)',
		'CREATE INDEX idx2_backups on backups (recipient,signatorial)',
		'CREATE INDEX idx3_backups on backups (recipient,signatorial,ost,reason)',
		'CREATE INDEX idx4_backups on backups (recipient,signatorial,reason)',
		# warehouse: stock/money lookups by item, place, source document and account
		'CREATE INDEX IF NOT EXISTS idx1_warehouse on warehouse (item)',
		'CREATE INDEX IF NOT EXISTS idx2_warehouse on warehouse (place)',
		'CREATE INDEX IF NOT EXISTS idx3_warehouse on warehouse (app_uuid)',
		'CREATE INDEX IF NOT EXISTS idx4_warehouse on warehouse (account)',
		'CREATE INDEX IF NOT EXISTS idx5_warehouse on warehouse (place,item)',
		# item catalog lookups are all "where app = ?"
		'CREATE INDEX IF NOT EXISTS idx1_model on model (app)',
		'CREATE INDEX IF NOT EXISTS idx1_option on option (app)',
		'CREATE INDEX IF NOT EXISTS idx1_option_category on option_category (app)',
		'CREATE INDEX IF NOT EXISTS idx1_subcategory on subcategory (app)',
		# settings_grabber reads by (app,device); setters read by (app,setting)
		'CREATE INDEX IF NOT EXISTS idx5_settings on settings (app,device)',
		'CREATE INDEX IF NOT EXISTS idx6_settings on settings (app,setting)',
		# transactions pull their documents by (type,app)
		'CREATE INDEX IF NOT EXISTS idx12_appts on appointments (type,app)',
		# inventory_details matches appointments by app or model; without an index
		# on model the model half of that or scans the whole table
		'CREATE INDEX IF NOT EXISTS idx13_appts on appointments (model)',
		# the peer sync check counts appointments above a watermark; server_time is
		# not a prefix of idx11 (app,server_time,status), so that count was a full
		# scan of the whole table on every two-minute tick
		'CREATE INDEX IF NOT EXISTS idx14_appts on appointments (server_time)',
		# remote machines are looked up by connection state and ip
		'CREATE INDEX IF NOT EXISTS idx1_remote_machines on remote_machines (connection)',
		'CREATE INDEX IF NOT EXISTS idx2_remote_machines on remote_machines (ip)',
		# mailbox reads by uuid, by (email,status), and by pen conversations
		'CREATE INDEX IF NOT EXISTS idx3_mailbox on mailbox (uuid)',
		'CREATE INDEX IF NOT EXISTS idx4_mailbox on mailbox (email,status)',
		'CREATE INDEX IF NOT EXISTS idx5_mailbox on mailbox (contact,conversation_uuid)',
		# Redundant indexes retired after a plans-and-usage audit: byte-for-byte
		# duplicates, prefixes of an index that is kept, or shapes the planner never
		# chose. The creates are gone from this list on purpose - leave one behind and
		# it would be recreated on the next run because migration_already_applied
		# checks sqlite_master rather than a ledger.
		'DROP INDEX IF EXISTS idx1_settings',
		'DROP INDEX IF EXISTS idx1_appts',
		'DROP INDEX IF EXISTS idx3_appts',
		'DROP INDEX IF EXISTS idx4_appts',
		'DROP INDEX IF EXISTS idx5_appts',
		'DROP INDEX IF EXISTS idx6_appts',
		'DROP INDEX IF EXISTS idx3_continent',
		'DROP INDEX IF EXISTS idx4_continent',
		'DROP INDEX IF EXISTS idx5_continent'
	];
	foreach my $t ( qw/model option option_category subcategory/) {
		foreach my $h ( qw/month day hour wday/ ) {
			push @{$commands}, 'alter table ' . $t . ' add column def_' . $h . ' VARCHAR(500)';
		}
	}
	if ($data->{'commands'}) {
		$commands = $data->{'commands'};
	}
	if ($data->{'duty'} eq 'list') {
		return $commands;
	}
	else {
		# The schema is migrated once per version, not on every call. The version
		# whose pass completed is kept in the database; while it still matches the
		# code's own version there is nothing new to apply. The commands are
		# idempotent and each carries its own guard, but that guard is a query per
		# command - and this runs at every login, every merge and every boot.
		my $current = &subs::jawn_version();
		my $local = $data->{'commands'} ? 0 : 1;
		if ($local) {
			my $applied = &subs::setting_grabber({ app => '__president', setting => 'schema_version' });
			return if $applied && $applied eq $current;
		}
		my ($db,$database,$sql) = &subs::database_grabber();
		my $failed = 0;
		foreach my $command (@{$commands}) {
			next if &migration_already_applied($command);
			my $ok = eval { &subs::db_query($command); 1 };
			$failed++ unless $ok;
		}
		# Deliberately no pragma tuning here. The handle is shared by the whole
		# process for its lifetime now, and the tuning that used to live here
		# (no busy timeout, no mmap, a 200MB page cache) ran after the commands
		# anyway - it could not have sped the migration up, it just left the
		# process failing every later contended write with "database is locked".
		# A one-off migration that wants its own settings should open its own
		# Mojo::SQLite, not borrow this one.
		# Statistics are the exception: after schema or index changes the planner's
		# numbers describe a database that no longer exists, and optimize only
		# re-runs ANALYZE where they are stale or missing. The alarm haircut carries
		# the same pair, for installs that have that utility switched on.
		eval { $db->query('PRAGMA analysis_limit=400;'); };
		eval { $db->query('PRAGMA optimize;'); };
		# data backfills ride the schema migration: any machine that receives the
		# new code runs the ones it has not recorded, at its next login / merge.
		&subs::run_backfills();
		# Only a clean pass records the version: a command that failed (a locked
		# database, say) has to be retried on the next call, never skipped because
		# the version moved on. A peer's command list is not ours to record from.
		if ($local && !$failed) {
			&subs::setting_setter({ app => '__president', setting => 'schema_version', value => $current });
		}
	}

	if (1 == 0) {
		my $settings = &subs::db_select('settings', undef, { setting => 'home_plate' })->hashes;
		foreach my $set ( grep { $_->{'app'} ne 'me' } @{$settings} ) {
			my $con = eval { return decode_json $set->{'value'} } || {};
			if ($con->{'latitude'}) {
				my $location = &subs::db_select('continent', undef, { app => $set->{'app'}, uuid => $con->{'uuid'} })->hashes->[0];
				if ($location->{'uuid'}) {
					&subs::db_update('continent', { type => 'home_plate' }, { uuid => $location->{'uuid'} });
				}
			}
		}
	}
	if ( 1 == 0 ) {
		my $settings = &subs::db_select('settings', undef, { setting => 'public' })->hashes;
		foreach my $set ( @{$settings} ) {
			&subs::db_update('settings', { value => 'on', server_time => &subs::rightNow() }, { app => $set->{'app'}, setting => $set->{'setting'}, uuid => $set->{'uuid'} });
		}
	}
	if (1 == 1) {
		my $q = &subs::db_query('select type from pragma_table_info(?) where name=?', 'cache', 'data')->hashes->[0]->{'type'};
		if ($q eq 'LONGTEXT') {
			&subs::db_query('ALTER TABLE cache ADD COLUMN s_data BLOB');
			my $caches = &subs::db_select('cache', undef, { s_data => undef })->hashes;
			foreach my $cache ( @{$caches} ) {
				my $d = eval { decode_json $cache->{'data'} };
        if ($@ || !$d) {
            next; # Skip to the next row safely
        }
				my $sd = eval { encode_sereal $d };
				&subs::db_update('cache', { s_data => $sd }, { uuid => $cache->{'uuid'}, app => $cache->{'app'} });
			}
			&subs::db_query('ALTER TABLE cache DROP COLUMN data');
			&subs::db_query('ALTER TABLE cache RENAME COLUMN s_data TO data');
		}
	}
}

1;
