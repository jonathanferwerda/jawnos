#!/usr/bin/env python3
"""Build the demo database the screenshot gallery starts from.

Starts from a pristine seeded database (schema + factory settings, no personal
rows), keeps its settings, and adds 35 days of synthetic but consistent life:
routines, watch steps, weather reads, notes, mail, people, tasks, money and
stock. Names and addresses are fictional; only the fixture mail addresses are
used.

    python3 scripts/gallery/seed/demo_seed.py \
        --seed .shots/seed.db --out .shots/demo.db

Run it on the capture machine. The result is copied into the live guest by
scripts/gallery/run.sh; the extra and gallery seeds run there afterwards.
"""
import argparse
import datetime
import json
import os
import random
import shutil
import sqlite3
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--seed", default=os.environ.get("DEMO_SEED", ".shots/seed.db"),
                    help="pristine schema+settings database (default: .shots/seed.db)")
parser.add_argument("--out", default=os.environ.get("DEMO_OUT", ".shots/demo.db"),
                    help="where to write the demo database (default: .shots/demo.db)")
args = parser.parse_args()

SEED = args.seed
OUT = args.out
DAY = 86400000
rnd = random.Random(11)
now = int(time.time() * 1000)
day_start = now - (now % DAY)

shutil.copyfile(SEED, OUT)
db = sqlite3.connect(OUT)
db.row_factory = sqlite3.Row
cur = db.cursor()


def uid(n=24):
    return uuid.uuid4().hex[:n]


def setting(app, key, value, device="computer", subsetting=""):
    cur.execute(
        "delete from settings where app=? and setting=? and device=? and ifnull(subsetting,'')=?",
        (app, key, device, subsetting),
    )
    cur.execute(
        "insert into settings (setting,value,timestamp,app,server_time,device,subsetting,uuid,ost) "
        "values (?,?,?,?,?,?,?,?,?)",
        (key, str(value), now, app, now, device, subsetting, uid(32), now),
    )


APPT_COLS = [
    "app", "timestamp", "data", "type", "account", "amount", "unit", "duration",
    "status", "notes", "vendor", "quantity", "total", "item", "server_time",
    "file", "device", "project", "pos", "club", "warranty", "source", "formulas",
    "position", "toggle", "uuid", "seen", "model", "option", "movement", "aux",
    "aux_description", "state", "has_tax", "has_totes", "ost", "balance",
    "measures", "manufacturer", "encryption_standard", "options", "source_uuid",
    "currency", "stop_seen", "stop_timestamp", "duties", "next_duty", "subtype",
    "app_uuid", "start_notes", "end_notes",
]


def appt(app, typ, ts, **kw):
    row = {k: None for k in APPT_COLS}
    row.update(
        app=app, type=typ, timestamp=str(ts), server_time=str(ts + 900),
        uuid=uid(32), device="computer", seen=kw.pop("seen", "yes"),
        ost=str(ts + 1000),
    )
    end = kw.pop("end", None)
    if end is not None:
        row["stop_timestamp"] = str(end)
        row["duration"] = str(-(end - ts))
        row["stop_seen"] = "yes"
    for k, v in kw.items():
        if k in row:
            row[k] = None if v is None else str(v) if not isinstance(v, (dict, list)) else json.dumps(v)
    places = ",".join(APPT_COLS)
    marks = ",".join("?" for _ in APPT_COLS)
    cur.execute(f"insert or replace into appointments ({places}) values ({marks})", [row[k] for k in APPT_COLS])
    return row


def session(app, start, minutes, notes="", project="", pos="idea", subtype=None):
    appt(app, "stop", start, end=start + minutes * 60000, notes=notes, project=project,
         pos=pos, subtype=subtype)


def measure(app, ts, items, pos="idea"):
    appt(app, "measure", ts, duration="1000", measures=items, pos=pos)


def note(app, ts, text, typ="note", project=""):
    appt(app, typ, ts, duration="600000", notes=text, project=project, pos="idea")


def transaction(app, ts, amount, vendor, account, movement, memo="", unit="ea", quantity="1"):
    sign = 1 if movement == "income" else -1
    total = round(amount * sign, 2)
    data = {
        "expense": {
            "totals": {"uuid": uid(10), "vendor": vendor, "amount": total,
                       "tax": 0, "aux": 0, "total": total},
        }
    }
    row = appt(app, "transaction", ts, amount=str(total), total=str(total),
               vendor=vendor, account=account, movement=movement,
               quantity=quantity, unit=unit, data=data, notes=memo,
               pos="thing")
    return row["uuid"], total, vendor, memo


# ---------------------------------------------------------------- settings
setting("misc", "appearance_theme", "nord")
setting("misc", "ui_zoom", "100")
setting("misc", "enc", "off")
setting("misc", "icon_set", "outline")
setting("misc", "taskbar_position", "top")
setting("misc", "taskbar_autohide", "off")
setting("misc", "clock_format", "12")
setting("misc", "navigation", "none")
setting("misc", "language", "en")
setting("me", "name", "Mara Ellison")
setting("me", "currency", "CAD")
setting("me", "budget", "9000steps/d")
setting("me", "colour", "#03ba64")
setting("me", "duration", "5m")
setting("me", "pos", "idea")
setting("me", "unit", "steps")

APP_META = {
    "drawing":     ("Create", "Art", "#36a1a1", "#2b7f7f", "45m", "10h/w", "idea"),
    "programming": ("Work", "Studio", "#5e81ac", "#4c6f94", "2h", "15h/w", "service"),
    "gallery":     ("Create", "Photos", "#cfe9aa", "#a9c487", "5m", "", "thing"),
    "music":       ("Create", "Music", "#1eef52", "#179f3a", "20m", "", "idea"),
    "studio":      ("Create", "Music", "#1eef52", "#179f3a", "45m", "", "idea"),
    "notes":       ("Think", "Notes", "#89d1c1", "#6aa89a", "5m", "", "idea"),
    "journal":     ("Think", "Journal", "#ec013d", "#b8002d", "10m", "", "idea"),
    "mail":        ("Work", "Mail", "#1a8364", "#12634a", "5m", "", "idea"),
    "mailbox":     ("Work", "Mail", "#36a1a1", "#2b7f7f", "5m", "", "idea"),
    "people":      ("People", "People", "#88dddd", "#62b3b3", "10m", "", "idea"),
    "tasks":       ("Work", "Tasks", "#40bfbf", "#2f8f8f", "10m", "", "idea"),
    "account":     ("Money", "Accounting", "#e7aefe", "#b785c4", "15m", "", "service"),
    "store":       ("Money", "Store", "#c5f1f1", "#93c4c4", "10m", "", "thing"),
    "warehouse":   ("Money", "Stock", "#e7aefe", "#b785c4", "10m", "", "thing"),
    "market":      ("Home", "Shopping", "#d7dbd9", "#a9b0ac", "10m", "", "thing"),
    "walk":        ("Body", "Walk", "#b3c3d7", "#8b9db3", "30m", "", "idea"),
    "sleep":       ("Body", "Sleep", "#4c566a", "#3b4252", "8h", "", "idea"),
    "breakfast":   ("Body", "Breakfast", "#d08770", "#a86a57", "20m", "", "idea"),
    "lunch":       ("Body", "Lunch", "#ebcb8b", "#bda25f", "30m", "", "idea"),
    "dinner":      ("Body", "Dinner", "#b48ead", "#8f6f8a", "45m", "", "idea"),
    "coffee":      ("Body", "Coffee", "#d08770", "#a86a57", "10m", "", "idea"),
    "read":        ("Mind", "Read", "#8fbcbb", "#6f9493", "30m", "", "idea"),
    "garden":      ("Home", "Garden", "#a3be8c", "#7d966b", "45m", "", "idea"),
    "medication":  ("Body", "Health", "#bf616a", "#944b52", "5m", "", "idea"),
    "health":      ("Body", "Health", "#bf616a", "#944b52", "5m", "", "idea"),
    "weather":     ("World", "Weather", "#64cece", "#4a9f9f", "5m", "", "event"),
    "mood":        ("Mind", "Mood", "#b48ead", "#8f6f8a", "5m", "", "idea"),
    "photos":      ("Create", "Photos", "#128f72", "#0d6b55", "5m", "", "thing"),
    "files":       ("System", "Files", "#5e81ac", "#4c6f94", "10m", "", "thing"),
    "clock":       ("System", "Clock", "#5e81ac", "#4c6f94", "5m", "", "thing"),
    "configure":   ("System", "Configure", "#5e81ac", "#4c6f94", "10m", "", "service"),
    "terminal":    ("System", "Terminal", "#394658", "#2b3441", "10m", "", "service"),
    "ide":         ("Work", "Code", "#5e81ac", "#4c6f94", "45m", "", "service"),
}
for app_name, (cat, sub, colour, dark, duration, budget, pos) in APP_META.items():
    setting(app_name, "category", cat)
    setting(app_name, "subcategory", sub)
    setting(app_name, "colour", colour)
    setting(app_name, "dark_colour", dark)
    setting(app_name, "duration", duration)
    setting(app_name, "pos", pos)
    setting(app_name, "warranty", "-10d")
    if budget:
        setting(app_name, "budget", budget)
    if app_name in ("drawing", "programming", "music", "studio"):
        setting(app_name, "aka", {"drawing": "draw,paint,sketch", "programming": "code,build",
                                  "music": "song,tune", "studio": "mix,record"}[app_name])
    if app_name in ("account", "store", "warehouse", "market"):
        setting(app_name, "movement", "expense")
    if app_name == "market":
        setting(app_name, "unit", "ea")

setting("weather", "app_measures", {
    "temperature": {"type": "number", "unit": "C", "min": "-40", "max": "45", "value": "12"},
    "humidity": {"type": "number", "unit": "%", "min": "0", "max": "100", "value": "62"},
    "condition": {"type": "text", "value": "partly_cloudy"},
})
setting("mood", "app_measures", {
    "mood": {"type": "number", "min": "1", "max": "10", "value": "7"},
    "energy": {"type": "number", "min": "1", "max": "10", "value": "6"},
    "focus": {"type": "number", "min": "1", "max": "10", "value": "7"},
})
setting("health", "app_measures", {
    "weight_kg": {"type": "number", "unit": "kg", "min": "40", "max": "150", "value": "68"},
    "systolic": {"type": "number", "unit": "mmHg", "min": "80", "max": "200", "value": "118"},
    "diastolic": {"type": "number", "unit": "mmHg", "min": "40", "max": "130", "value": "76"},
    "resting_hr": {"type": "number", "unit": "bpm", "min": "40", "max": "120", "value": "62"},
})
setting("me", "app_measures", {
    "steps": {"type": "number", "unit": "steps", "value": "9000"},
    "speed": {"type": "number", "unit": "km/h", "value": "0"},
})

# ---------------------------------------------------------------- clothesline
clothesline = [
    ("sleep", "Sleep", "#acb2bd", "#4c566a"),
    ("walk", "Walk", "#b3c3d7", "#5e81ac"),
    ("breakfast", "Breakfast", "#e1c5bf", "#d08770"),
    ("coffee", "Coffee", "#d08770", "#a86a57"),
    ("drawing", "Draw", "#c7dbdd", "#8fbcbb"),
    ("lunch", "Lunch", "#ece1ca", "#ebcb8b"),
    ("programming", "Studio", "#c1d0e0", "#81a1c1"),
    ("dinner", "Dinner", "#d6c8d8", "#b48ead"),
    ("read", "Read", "#c7dbdd", "#8fbbbb"),
    ("journal", "Journal", "#dab6bd", "#bf616a"),
]
setting("__president", "clothesline", [
    {"app": a, "name": a, "formatted_name": n, "colour": c, "dark_colour": d}
    for a, n, c, d in clothesline
])

# ---------------------------------------------------------------- tasks
tasks = []
task_seed = [
    ("Invoice Northlight Gallery", 9, "off", 0),
    ("Order archival paper", 7, "off", 0),
    ("Send Meridian Health proofs", 8, "off", 0),
    ("Back up studio drive", 4, "on", 7),
    ("Plan November print run", 6, "off", 0),
    ("Water the studio plants", 2, "on", 2),
    ("Update portfolio site", 5, "off", 0),
    ("Call Eleanor", 8, "off", 0),
    ("Renew software licence", 6, "off", 0),
    ("Sort reference photos", 3, "off", 0),
    ("Book the framer", 7, "off", 0),
    ("Write October journal", 4, "off", 0),
]
for i, (label, prio, done, last_days) in enumerate(task_seed):
    tasks.append({
        "uuid": uid(20), "task": label, "timestamp": now - (i + 1) * DAY,
        "completed": done, "priority": prio,
        "colour": ["#5e81ac", "#8fbcbb", "#b48ead", "#a3be8c", "#d08770"][i % 5],
        "renew_freq": 0 if i % 4 else 7 * DAY,
        "last_completed": now - last_days * DAY if last_days else 0,
        "duration": 0, "occurences": 0, "appt": "off", "account": "",
        "movement": "", "project": "",
    })
setting("tasks", "tasks", json.dumps(tasks))

# ---------------------------------------------------------------- people
people = [
    ("Mara Ellison", "citizen"), ("Daniel Brooks", "citizen"),
    ("Priya Shah", "citizen"), ("Jonah Reed", "citizen"),
    ("Eleanor Whitfield", "resident"), ("Ruth Whitfield", "resident"),
    ("Tom Alvarez", "resident"), ("Northlight Gallery", "resident"),
    ("Cedar & Co.", "resident"), ("Meridian Health", "resident"),
    ("Civic Works", "resident"), ("Harbourfront Arts", "guest"),
]
for name, priv in people:
    cur.execute(
        "insert or replace into people (uuid,name,privilege,status,created,ost,server_time,app) "
        "values (?,?,?,?,?,?,?,?)",
        (uid(24), name, priv, "active", now - 400 * DAY, now, now, ""),
    )
    setting(name, "colour", "#88dddd")
    setting(name, "aka", name.lower().replace(" ", "_"))

# ---------------------------------------------------------------- month
client_projects = ["Northlight Gallery", "Meridian Health", "Civic Works", "Harbourfront Arts"]
mail_contacts = [
    ("Daniel Brooks", "email_test@example.com"),
    ("Priya Shah", "email_tester@example.com"),
    ("Eleanor Whitfield", "email_test@example.com"),
    ("Northlight Gallery", "email_tester@example.com"),
    ("Meridian Health", "email_test@example.com"),
    ("Jonah Reed", "email_tester@example.com"),
]
mail_subjects = [
    ("Northlight show — delivery dates", "The framed pieces arrive Tuesday. Can we book the wall walk for Wednesday morning?"),
    ("Meridian proofs", "The second round of proofs is attached. The blue reads beautifully in print."),
    ("Sunday dinner", "Come by around four. I am making the squash soup you like."),
    ("Invoice received", "Thank you — the invoice is with accounts and should clear this week."),
    ("Studio visit", "I would love to see the new work before it goes up. Any afternoon next week?"),
    ("Paper order", "Your archival paper is in. We held the roll until Friday."),
    ("A walk this weekend", "The leaves are turning by the ravine. Saturday morning?"),
    ("Contract for the lobby piece", "The board approved the commission. Sending the paperwork today."),
]
journal_lines = [
    "A slow start, then the light came through the studio window and the whole day changed. I worked the underlayer on the big canvas and stopped before I overworked it.",
    "Too many small errands, not enough paint. Tomorrow I keep the morning clear.",
    "The proofs came back and the blue is right. I sent them on and took a long walk by the water.",
    "I am learning to leave the edges alone. The piece is better where I let it breathe.",
    "A good studio day. Four hours, one idea, no phone.",
    "Rain all morning. I sorted reference photos and found the harbour series again.",
    "Dinner with Eleanor. She told the story about the blue house and I wrote it down after.",
    "Invoiced two clients and paid the paper bill. The admin is not the work, but it keeps the work possible.",
    "A quiet day. I read, watered the plants, and made a small sketch that might become something.",
    "The commission is real now. I measured the lobby wall twice and started a maquette.",
]
notes_lines = [
    "Try a warmer ground under the harbour series.",
    "Paper: 300 gsm, cold press. Order two rolls.",
    "Northlight wants the small pieces hung lower.",
    "Call the framer about the walnut frame.",
    "The blue in the Meridian proof is closer to the original.",
    "Book the van for Tuesday.",
    "Studio insurance renews on the 14th.",
    "Reference: the light at the market around four.",
    "Eleanor's birthday is the 19th.",
    "Ask Priya about the community wall.",
]

for i in range(34, -1, -1):
    d0 = day_start - i * DAY
    weekday = datetime.datetime.utcfromtimestamp(d0 / 1000).weekday()
    # night before
    session("sleep", d0 - 3600000, 470 + rnd.randint(-25, 30),
            notes="", pos="idea")
    session("breakfast", d0 + 7 * 3600000 + 30 * 60000, 25)
    session("coffee", d0 + 8 * 3600000, 12)
    session("walk", d0 + 8 * 3600000 + 30 * 60000, 35 + rnd.randint(0, 20), project="Harbourfront")
    # studio morning
    session("drawing", d0 + 9 * 3600000 + 15 * 60000, 150 + rnd.randint(-20, 40),
            notes="Underlayer and blocking on the harbour piece.", project=client_projects[i % 4])
    session("lunch", d0 + 12 * 3600000 + 15 * 60000, 30)
    # afternoon work
    if weekday < 5:
        session("programming", d0 + 13 * 3600000 + 15 * 60000, 150 + rnd.randint(-30, 60),
                notes="Client site and the archive tool.", project=client_projects[(i + 1) % 4])
    if weekday in (1, 4):
        session("garden", d0 + 16 * 3600000 + 30 * 60000, 40)
    session("dinner", d0 + 18 * 3600000, 45)
    session("read", d0 + 20 * 3600000, 35 + rnd.randint(0, 20))
    note("journal", d0 + 21 * 3600000 + 30 * 60000, journal_lines[i % len(journal_lines)])
    # notes
    if i % 2 == 0:
        note("notes", d0 + 10 * 3600000 + rnd.randint(0, 59) * 60000, notes_lines[(i // 2) % len(notes_lines)])
    if i % 5 == 0:
        note("notes", d0 + 17 * 3600000 + 20 * 60000, "Follow up: " + notes_lines[(i // 5) % len(notes_lines)])
    # watch steps, every 30 min while awake
    for h in range(7, 23):
        for m in (0, 30):
            ts = d0 + h * 3600000 + m * 60000
            walking = (h == 8 and m in (30,)) or (h == 16 and m == 30)
            steps = rnd.randint(260, 620) if walking else rnd.randint(70, 340)
            measure("me", ts, [
                {"steps": steps, "timestamp": ts, "uuid": uid(20)},
                {"speed": "4.6" if walking else "0.0", "ts": ts},
            ])
    # weather every 3h
    for h in (0, 3, 6, 9, 12, 15, 18, 21):
        ts = d0 + h * 3600000 + rnd.randint(0, 30) * 60000
        temp = round(9 + 6 * (h / 24.0) + rnd.uniform(-2.5, 2.5), 1)
        measure("weather", ts, [
            {"temperature": str(temp), "ts": ts, "uuid": uid(20)},
            {"humidity": str(rnd.randint(52, 82)), "ts": ts + 100},
            {"condition": rnd.choice(["partly_cloudy", "mostly_cloudy", "clear", "light_rain"]), "ts": ts + 200},
        ], pos="event")
    # mood
    measure("mood", d0 + 21 * 3600000, [
        {"mood": rnd.randint(6, 9), "ts": d0 + 21 * 3600000},
        {"energy": rnd.randint(4, 8), "ts": d0 + 21 * 3600000},
        {"focus": rnd.randint(4, 9), "ts": d0 + 21 * 3600000},
    ])
    # health every other day
    if i % 2 == 0:
        measure("health", d0 + 8 * 3600000 + 10 * 60000, [
            {"weight_kg": str(round(68.2 + rnd.uniform(-0.7, 0.7), 1)), "ts": d0 + 8 * 3600000},
            {"systolic": str(rnd.randint(112, 124)), "ts": d0 + 8 * 3600000},
            {"diastolic": str(rnd.randint(70, 80)), "ts": d0 + 8 * 3600000},
            {"resting_hr": str(rnd.randint(57, 68)), "ts": d0 + 8 * 3600000},
        ])
    # mail
    if i % 2 == 0:
        contact, email = mail_contacts[(i // 2) % len(mail_contacts)]
        subj, body = mail_subjects[(i // 2) % len(mail_subjects)]
        cur.execute(
            "insert into mailbox (uuid,timestamp,server_time,body,app,status,contact,person,email,"
            "subject,from_email,sender,seen,starred,thread,conversation_uuid,message_id,ost) "
            "values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (uid(32), str(d0 + 9 * 3600000), str(d0 + 9 * 3600000 + 500), body, "mailbox",
             "received", contact, contact, email, subj, email,
             "contact", "yes" if i % 4 else "no", "yes" if i % 6 == 0 else "",
             "thread-" + str(i // 2), "conv-" + str(i // 2), "msg-" + uid(12), str(d0)),
        )
    if weekday == 2:
        cur.execute(
            "insert into mailbox (uuid,timestamp,server_time,body,app,status,contact,person,email,"
            "subject,from_email,sender,seen,starred,thread,conversation_uuid,message_id,ost) "
            "values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (uid(32), str(d0 + 11 * 3600000), str(d0 + 11 * 3600000 + 500),
             "Attached is the revised estimate. Let me know if the timeline works.",
             "mailbox", "sent", mail_contacts[0][0], mail_contacts[0][0],
             mail_contacts[0][1], "Revised estimate", "email_tester@example.com",
             "me", "yes", "", "thread-out-" + str(i), "conv-out-" + str(i),
             "msg-" + uid(12), str(d0)),
        )

# ---------------------------------------------------------------- money
accounts = [
    ("1000", "Cash", "asset", "debit"),
    ("1100", "Accounts Receivable", "asset", "debit"),
    ("2000", "Accounts Payable", "liability", "credit"),
    ("3000", "Owner's Equity", "equity", "credit"),
    ("4000", "Design Income", "income", "credit"),
    ("5000", "Art Supplies", "expense", "debit"),
    ("5010", "Software", "expense", "debit"),
    ("5020", "Studio Rent", "expense", "debit"),
    ("5030", "Groceries", "expense", "debit"),
]
for code, name, typ, normal in accounts:
    cur.execute(
        "insert or replace into ledger_accounts (uuid,code,name,type,normal,app,parent,active,server_time,ost) "
        "values (?,?,?,?,?,?,?,?,?,?)",
        (uid(24), code, name, typ, normal, "account", "", "on", now, now),
    )


def post(ts, debit_code, credit_code, amount, memo, source_uuid, app="account", cash="1000"):
    entry = source_uuid
    cur.execute(
        "insert into journal (uuid,entry_uuid,timestamp,account_code,debit,credit,currency,memo,"
        "source_uuid,source_kind,app,account,server_time,ost) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (entry + "-1", entry, str(ts), debit_code, f"{amount:.4f}", "0.0000", "CAD", memo,
         source_uuid, "money", app, cash, str(ts + 1000), str(ts + 1000)),
    )
    cur.execute(
        "insert into journal (uuid,entry_uuid,timestamp,account_code,debit,credit,currency,memo,"
        "source_uuid,source_kind,app,account,server_time,ost) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (entry + "-2", entry, str(ts), credit_code, "0.0000", f"{amount:.4f}", "CAD", memo,
         source_uuid, "money", app, cash, str(ts + 1000), str(ts + 1000)),
    )


money_rows = []
for i in range(34, -1, -1):
    d0 = day_start - i * DAY
    weekday = datetime.datetime.utcfromtimestamp(d0 / 1000).weekday()
    if weekday == 0 and i % 7 == 0:
        src, total, vendor, memo = transaction("account", d0 + 10 * 3600000, 2400.00,
                                               "Northlight Gallery", "chequing", "income",
                                               "Commission — harbour series")
        post(d0 + 10 * 3600000, "1000", "4000", 2400.00, "Commission", src)
        money_rows.append((d0, "income", 2400.00, "Northlight Gallery"))
    if weekday == 3 and i % 7 == 0:
        src, total, vendor, memo = transaction("account", d0 + 10 * 3600000, 1800.00,
                                               "Meridian Health", "chequing", "income",
                                               "Lobby artwork")
        post(d0 + 10 * 3600000, "1000", "4000", 1800.00, "Lobby artwork", src)
        money_rows.append((d0, "income", 1800.00, "Meridian Health"))
    if i % 6 == 0:
        src, total, vendor, memo = transaction("account", d0 + 14 * 3600000, 186.40,
                                               "Harbour Art Supply", "chequing", "expense",
                                               "Archival paper and ink")
        post(d0 + 14 * 3600000, "5000", "1000", 186.40, "Paper and ink", src)
        money_rows.append((d0, "expense", 186.40, "Harbour Art Supply"))
    if i == 34 or i == 4:
        src, total, vendor, memo = transaction("account", d0 + 9 * 3600000, 1450.00,
                                               "Ravine Studio", "chequing", "expense",
                                               "Studio rent")
        post(d0 + 9 * 3600000, "5020", "1000", 1450.00, "Studio rent", src)
        money_rows.append((d0, "expense", 1450.00, "Ravine Studio"))
    if weekday in (0, 4):
        src, total, vendor, memo = transaction("account", d0 + 17 * 3600000, 84.20,
                                               "Market", "chequing", "expense",
                                               "Groceries")
        post(d0 + 17 * 3600000, "5030", "1000", 84.20, "Groceries", src)
        money_rows.append((d0, "expense", 84.20, "Market"))

# ---------------------------------------------------------------- stock
stock = [
    ("Archival paper — cold press", "24", "sheet", "Studio shelf", "paper"),
    ("Archival paper — hot press", "18", "sheet", "Studio shelf", "paper"),
    ("Carbon ink — black", "6", "bottle", "Ink drawer", "ink"),
    ("Ultramarine pigment", "3", "jar", "Pigment shelf", "pigment"),
    ("Canvas — 90 cm", "4", "roll", "Back wall", "canvas"),
    ("Coffee — filter roast", "2", "bag", "Kitchen", "coffee"),
    ("Tea — earl grey", "1", "box", "Kitchen", "tea"),
    ("Packing tape", "5", "roll", "Desk", "packing"),
]
for item, qty, unit, place, kind in stock:
    cur.execute(
        "insert or replace into warehouse (timestamp,server_time,item,model,options,uuid,ost,device,"
        "quantity,unit,data,serial_number,batch_uuid,app_uuid,place,type,project,account,warranty) "
        "values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (str(now - 3 * DAY), str(now), item, "", "", uid(24), str(now), "computer",
         qty, unit, json.dumps({"reorder": "4" if kind in ("paper", "ink") else ""}),
         "", "", "", place, "inventory", "", "", "-10d"),
    )

store_items = [
    ("Archival print — small", "145.00", "48.00", "print", "Edition of 25, cotton rag, signed."),
    ("Archival print — large", "320.00", "96.00", "print", "Edition of 10, 60 × 80 cm, signed."),
    ("Studio consultation", "180.00", "0.00", "service", "Two hours on a project, portfolio or wall."),
    ("Hand-bound sketchbook", "65.00", "22.00", "object", "Linen cover, 120 pages, made in the studio."),
]
for name, price, cost, unit, desc in store_items:
    cur.execute(
        "insert or replace into model (app,name,price,characteristics,timestamp,server_time,uuid,"
        "files,cost,description,discount,markup,ost,manufacturer,def,quantity,unit,save_app) "
        "values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("store", name, price, json.dumps({"edition": "25", "paper": "cotton rag"}),
         str(now - 10 * DAY), str(now), uid(24), "", cost, desc, "0", "0", str(now),
         "Mara Ellison", "on", "1", unit, "store"),
    )

db.commit()
counts = {t: cur.execute(f"select count(*) from {t}").fetchone()[0]
          for t in ("appointments", "settings", "mailbox", "people", "journal",
                    "ledger_accounts", "warehouse", "model")}
print(counts)
db.close()
