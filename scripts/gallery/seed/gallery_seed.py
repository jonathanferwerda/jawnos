"""Seed the Gallery albums from the demo photos in the live guest.

    python3 gallery_seed.py [database path]

The photos are staged by scripts/gallery/seed/media.sh; the paths recorded in
the database are the guest's own (~/Pictures/<album>). Safe to run while the
tree is up: it replaces each album row and its settings in place.
"""
import json, os, sqlite3, sys, time, uuid

DB = sys.argv[1] if len(sys.argv) > 1 else '/home/jawn/jawnos/database/jawnos.db'
HOME = os.path.expanduser('~')
now = int(time.time() * 1000)
db = sqlite3.connect(DB)
cur = db.cursor()

albums = {
    't-watch': ('T-Watch', '#88c0d0', '#5e81ac'),
    't-deck': ('T-Deck', '#a3be8c', '#7d966b'),
    'studio': ('Studio', '#5e81ac', '#4c6f94'),
    'plein_air': ('Plein Air', '#a3be8c', '#7d966b'),
    'portraits': ('Portraits', '#b48ead', '#8f6f8a'),
}


def setting(app, key, val):
    cur.execute("delete from settings where app=? and setting=? and device='computer'", (app, key))
    cur.execute(
        "insert into settings (setting,value,timestamp,app,server_time,device,subsetting,uuid,ost) "
        "values (?,?,?,?,?,?,?,?,?)",
        (key, val, now, app, now, 'computer', '', uuid.uuid4().hex[:24], now),
    )


for app, (folder, colour, dark) in albums.items():
    cur.execute("delete from appointments where app=?", (app,))
    files = []
    root = os.path.join(HOME, 'Pictures', folder)
    for fn in sorted(os.listdir(root)):
        if not fn.lower().endswith(('.jpg', '.jpeg', '.png')):
            continue
        path = os.path.join(root, fn)
        files.append({
            'f': path, 'type': 'image', 'uuid': uuid.uuid4().hex[:8],
            'of': fn, 'info': {'width': '1600', 'height': '1200'},
            'server_time': str(now), 'timestamp': str(now),
        })
    if not files:
        continue
    cur.execute(
        "insert into appointments (app,timestamp,type,file,server_time,device,uuid,seen,ost,pos) "
        "values (?,?,?,?,?,?,?,?,?,?)",
        (app, str(now), 'image', json.dumps(files), str(now), 'computer',
         uuid.uuid4().hex[:32], 'yes', str(now), 'thing'),
    )
    setting(app, 'category', 'Create')
    setting(app, 'subcategory', 'Photos')
    setting(app, 'colour', colour)
    setting(app, 'dark_colour', dark)
    setting(app, 'pos', 'thing')
    setting(app, 'duration', '5m')
    setting(app, 'warranty', '-10d')

# The warehouse is a text list; an em dash became mojibake in the window.
cur.execute("update warehouse set item=replace(replace(item, '—', '-'), 'â€”', '-')")

db.commit()
print('albums', [(a, len(os.listdir(os.path.join(HOME, 'Pictures', f)))) for a, (f, _, _) in albums.items()])
db.close()
