#!/usr/bin/env python3
"""Make a car's hook map from Car Reports (the map the car made of itself).

usage: report-map.py <car-report.json>... [--maps DIR] [--status probed]
                     [--make MAKE] [--name NAME]

Each report holds the on-car mapper's result ("map_car": points, the md5 of every
file the names came from, what it didn't find). Give one or more reports from the
same model, region and firmware: their points must agree, and every file md5 must be
the same in a majority of them (a car whose apps were changed by another package
reports other md5s; it's outvoted, and named). Writes
maps/<make>/<model>/<region>/<firmware>/ in map-car.py's format, status "probed".
Names and md5s only: nothing else from the reports is kept.
"""
import argparse, collections, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('reports', nargs='+')
    ap.add_argument('--maps', default=os.path.join(REPO, 'maps'))
    ap.add_argument('--status', default='probed', choices=('probed', 'mapped'))
    ap.add_argument('--make', help='car make when the report does not identify it')
    ap.add_argument('--name', help='display name when the report does not identify it')
    a = ap.parse_args()
    reps = []
    for f in a.reports:
        r = json.load(open(f))
        if r.get('report') != 'hmgapi car report 1' or 'map_car' not in r:
            sys.exit('%s: not a Car Report with an on-car map' % f)
        reps.append((os.path.basename(f), r))
    u = reps[0][1]['unit']
    make = a.make or u.get('make')
    if not make:
        sys.exit('%s: the report has no unit.make; pass --make' % reps[0][0])
    key = lambda r: (r['unit']['model'], r['unit']['region'], r['unit']['firmware'])
    for name, r in reps:
        if key(r) != key(reps[0][1]):
            sys.exit('%s is %s, not %s' % (name, '.'.join(key(r)), '.'.join(key(reps[0][1]))))
    mc = reps[0][1]['map_car']
    for name, r in reps[1:]:
        if r['map_car']['points'] != mc['points']:
            sys.exit('%s: its points differ from %s; map them separately' % (name, reps[0][0]))
    files = {}
    for path in sorted(set().union(*[r['map_car']['files'] for _, r in reps])):
        votes = collections.Counter(r['map_car']['files'].get(path) for _, r in reps)
        md5, n = votes.most_common(1)[0]
        if md5 is None or n * 2 <= len(reps):
            sys.exit('%s: no majority md5 (%s)' % (path, dict(votes)))
        files[path] = md5
        for name, r in reps:
            if r['map_car']['files'].get(path) != md5:
                print('outvoted: %s %s is %s' % (name, path, r['map_car']['files'].get(path)))
    by_app = {app: {} for app in mc['app_files']}
    for pid, e in mc['points'].items():
        by_app[pid.split('.')[0]][pid] = e
    d = os.path.join(a.maps, make.lower(), u['model'].lower(), u['region'].lower(), u['firmware'])
    os.makedirs(d, exist_ok=True)
    car = {
        'make': make.lower(), 'model': u['model'].lower(), 'name': a.name or u.get('name') or u['model'],
        'region': u['region'].lower(), 'firmware': u['firmware'],
        'products': ['%s.%s.' % (u['model'], u['region'])],
        'status': a.status, 'verified': None,
        'files': files,
        'apps': sorted(by_app),
        'app_files': mc['app_files'],
    }
    # Reports call this not_found; accept missing as well for older report producers.
    missing = {k: v for k, v in mc.get('not_found', mc.get('missing', {})).items()}
    if missing:
        car['missing'] = dict(sorted(missing.items()))
    if mc.get('by_reference'):
        car['by_reference'] = sorted(mc['by_reference'])
    for app, entries in by_app.items():
        with open(os.path.join(d, app + '.json'), 'w') as f:
            json.dump(dict(sorted(entries.items())), f, indent=2)
            f.write('\n')
    with open(os.path.join(d, 'car.json'), 'w') as f:
        json.dump(car, f, indent=2)
        f.write('\n')
    print('%s: %d points, %d missing, from %d report(s)' % (os.path.relpath(d, REPO), len(mc['points']), len(missing), len(reps)))


if __name__ == '__main__':
    main()
