#!/usr/bin/env python3
"""Extra demo data for the travel/continent, wallpapers and Clock shots.

Run inside the demo VM after the base seed is in place:
    python3 demo_extra_seed.py /home/jawn/jawnos/database/jawnos.db
The map/background files are expected under ~/Pictures/travel and
~/Pictures/Backgrounds (copied by the capture setup).
"""
import json
import math
import os
import sqlite3
import sys
import time
import uuid

DB = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/jawnos/database/jawnos.db')
HOME = os.path.expanduser('~')
now = int(time.time() * 1000)
db = sqlite3.connect(DB)
db.row_factory = sqlite3.Row
cur = db.cursor()


def uid(n=24):
    return uuid.uuid4().hex[:n]


def setting(app, key, value, device='computer', subsetting=''):
    cur.execute(
        "delete from settings where app=? and setting=? and device=? and ifnull(subsetting,'')=?",
        (app, key, device, subsetting),
    )
    cur.execute(
        "insert into settings (setting,value,timestamp,app,server_time,device,subsetting,uuid,ost) "
        "values (?,?,?,?,?,?,?,?,?)",
        (key, value if isinstance(value, str) else json.dumps(value), now, app, now, device,
         subsetting, uid(32), now),
    )


# ---------------------------------------------------------------- travel maps
# Home plates are pixels at a latitude/longitude; the scale bar gives metres per
# pixel. The bounds are the arithmetic Manager.pl's travel_map_bounds() uses.
MAPS = [
    {
        'uuid': 'demo-harbour', 'name': 'Harbourfront', 'file': 'travel/harbour.jpg',
        'w': 1600, 'h': 1200, 'lat': 42.9750, 'lon': -82.4050,
        'ppm': 1.25, 'bar_px': 400, 'bar_m': 500,
    },
    {
        'uuid': 'demo-ravine', 'name': 'Ravine Park', 'file': 'travel/ravine.jpg',
        'w': 1200, 'h': 900, 'lat': 42.9750, 'lon': -82.3885,
        'ppm': 0.8, 'bar_px': 400, 'bar_m': 320,
    },
]
maps = []
for m in MAPS:
    x, y = m['w'] / 2, m['h'] / 2
    maps.append({
        'uuid': m['uuid'], 'app': 'travel', 'type': 'image', 'function': 'map',
        'name': m['name'], 'f': os.path.join(HOME, 'Pictures', m['file']),
        'rotate': 0, 'server_time': str(now),
        'home_plate': {
            'x': x, 'y': y, 'width': m['w'], 'height': m['h'],
            'latitude': m['lat'], 'longitude': m['lon'],
            'legend': m['name'], 'formatted_legend': m['name'],
        },
        'scale': {
            'first': {'x': 80, 'y': m['h'] - 50},
            'last': {'x': 80 + m['bar_px'], 'y': m['h'] - 50},
            'width': m['w'], 'height': m['h'],
            'legend': m['bar_m'], 'formatted_legend': str(m['bar_m']) + ' m',
        },
    })
setting('travel', 'maps', maps)
setting('travel', 'map_provider', 'none')
setting('travel', 'home_plate_enabled', 'enabled')
setting('travel', 'guess_enabled', 'off')

# The person's own home plate: the harbour plate, at the point the track starts.
setting('me', 'home_plate', {'latitude': 42.9750, 'longitude': -82.4050,
                             'label': 'Home', 'legend': 'Home'})
setting('walk', 'home_plate', {'latitude': 42.9750, 'longitude': -82.4050,
                               'label': 'Home', 'legend': 'Home'})

# ---------------------------------------------------------------- backgrounds
wallpapers = [
    ('harbour-dawn.jpg', 'Harbour, dawn'),
    ('studio-window.jpg', 'Studio window'),
    ('forest-edge.jpg', 'Field edge'),
    ('paper-desk.jpg', 'Paper'),
]
backgrounds = []
for fn, name in wallpapers:
    backgrounds.append({
        'uuid': uid(24), 'app': 'gallery', 'app_uuid': '', 'type': 'image',
        'function': 'background', 'of': fn, 'f': os.path.join(HOME, 'Pictures', 'Backgrounds', fn),
        'info': {'width': '1920', 'height': '1080'},
        'timestamp': str(now), 'server_time': str(now),
    })
setting('marker', 'backgrounds', backgrounds)

# ---------------------------------------------------------------- location
cur.execute("delete from continent where uuid like 'demo-%' or app='__president'")
TRACK = []
# a harbour walk: out along the shore, back through the ravine
way = [
    (42.9746, -82.4086), (42.9752, -82.4081), (42.9758, -82.4075),
    (42.9764, -82.4068), (42.9770, -82.4059), (42.9774, -82.4049),
    (42.9779, -82.4039), (42.9783, -82.4029), (42.9785, -82.4019),
    (42.9791, -82.4010), (42.9798, -82.4003), (42.9806, -82.3997),
    (42.9813, -82.3992), (42.9820, -82.3988), (42.9825, -82.3984),
]
for i, (lat, lon) in enumerate(way):
    TRACK.append(('walk', lat, lon, now - (len(way) - i) * 90000, '3.1' if i % 3 else '4.4'))


def continent(app, lat, lon, ts, typ='app', speed='', accuracy='6.00'):
    cur.execute(
        "insert or replace into continent (latitude,longitude,accuracy,timestamp,operator,"
        "operator_door,server_time,uuid,type,scope,app,warranty,ost,speed,altitude) "
        "values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (f'{lat:.6f}', f'{lon:.6f}', accuracy, str(ts), 'demo', '', str(ts), 'demo-' + uid(18),
         typ, '', app, '', str(ts), speed, ''),
    )


for app, lat, lon, ts, speed in TRACK:
    continent(app, lat, lon, ts, speed=speed)
# a few places the other apps were used, to scatter markers over the maps
for app, lat, lon in [
    ('gallery', 42.9762, -82.4044), ('gallery', 42.9808, -82.4006),
    ('drawing', 42.9751, -82.4055), ('programming', 42.9771, -82.4022),
    ('read', 42.9818, -82.3990), ('mail', 42.9767, -82.4062),
]:
    continent(app, lat, lon, now - 7200000)
# the machine's current place
continent('__president', 42.9780, -82.4030, now, typ='temporary')
cur.execute("update continent set warranty=? where app='__president' and type='temporary'",
            (str(now + 6 * 3600000),))

# ---------------------------------------------------------------- clock
alarms = [
    {'uuid': uid(24), 'hour': 6, 'minute': 40, 'days': [1, 2, 3, 4, 5], 'enabled': 1,
     'label': 'Studio morning', 'app': 'drawing', 'sound': 'notifications/ring.mp3',
     'volume': 70, 'ramp': 60, 'snooze': 5, 'play': '', 'nfc': 0, 'nfc_action': 'snooze',
     'machines': ['me'], 'updated': now, 'created': now},
    {'uuid': uid(24), 'hour': 7, 'minute': 15, 'days': [0, 6], 'enabled': 1,
     'label': 'Slow start', 'app': '', 'sound': 'notifications/ring.mp3',
     'volume': 55, 'ramp': 120, 'snooze': 10, 'play': '', 'nfc': 0, 'nfc_action': 'snooze',
     'machines': ['me'], 'updated': now, 'created': now},
    {'uuid': uid(24), 'hour': 21, 'minute': 30, 'days': [0, 1, 2, 3, 4, 5, 6], 'enabled': 0,
     'label': 'Wind down', 'app': '', 'sound': 'notifications/ring.mp3',
     'volume': 40, 'ramp': 90, 'snooze': 5, 'play': '', 'nfc': 0, 'nfc_action': 'snooze',
     'machines': ['me'], 'updated': now, 'created': now},
]
setting('clock', 'alarms', alarms, device='house')
timers = [
    {'uuid': uid(24), 'label': 'Tea', 'seconds': 300, 'started_at': now - 120000,
     'ends_at': now + 180000, 'ended_at': 0, 'state': 'running', 'app': '',
     'appt_uuid': '', 'sound': '', 'created': now},
]
setting('clock', 'timers', timers)

# keep the app lists honest
setting('travel', 'category', 'World')
setting('travel', 'subcategory', 'Maps')
setting('travel', 'colour', '#64cece')
setting('travel', 'dark_colour', '#4a9f9f')
setting('travel', 'duration', '10m')
setting('travel', 'pos', 'event')

db.commit()
print('travel maps', cur.execute("select count(*) from settings where app='travel' and setting='maps'").fetchone()[0])
print('backgrounds', len(backgrounds))
print('continent', cur.execute("select count(*) from continent").fetchone()[0])
print('clock alarms', len(alarms))
db.close()
