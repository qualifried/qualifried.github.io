# Counts your local Claude Code activity since 2026-10-01. Counts only: no message text is saved.
# Output: claude-usage-counts-<machine>.json on your Desktop. Prints PASS/FAIL at the end.
import json, os, re, socket, sys, glob, datetime

root = os.path.expanduser('~/.claude/projects')
since = '2026-10-01'
host = socket.gethostname().split('.')[0]
desk = os.path.expanduser('~/Desktop')
out = os.path.join(desk if os.path.isdir(desk) else os.path.expanduser('~'), f'claude-usage-counts-{host}.json')
if not os.path.isdir(root):
    print('FAIL: folder not found:', root); sys.exit()

W = re.compile(r'\S+')
PASTE = re.compile(r'<pasted_content[^>]*>(.*?)</pasted_content', re.S)
RI = re.compile(r'"(?:content|text)":"\[Request interrupted by user')
RQ = re.compile(r'"(?:content|text)":"(?:User has answered|Your questions have been answered)')
SKIP = ('<local-command', 'Caveat:', '<task-notification>', '<system-reminder>', 'This session is being continued')
rows, sess, nfiles, nbad = {}, [], 0, 0

def bump(k, f, n=1):
    r = rows.setdefault(k, dict(m=0, w=0, pw=0, i=0, s=0, a=0, t=0, q=0))
    r[f] += n

for path in glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True):
    if datetime.datetime.fromtimestamp(os.path.getmtime(path)).strftime('%Y-%m-%d') < since:
        continue
    nfiles += 1
    rel = os.path.relpath(path, root).split(os.sep)
    proj, sub = rel[0], len(rel) > 2
    first = last = None; msgs = 0
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = re.search(r'"timestamp":"(\d{4}-\d\d-\d\dT\d\d)', line)
            if not m or m.group(1) < since:
                continue
            h = m.group(1); first = first or h; last = h; k = f'{proj}|{h}'
            if '"type":"assistant"' in line:
                bump(k, 'a'); bump(k, 't', line.count('"type":"tool_use"')); continue
            if '"type":"user"' not in line or sub:
                continue
            if '"tool_use_id"' in line:
                if RI.search(line): bump(k, 'i')
                if RQ.search(line): bump(k, 'q')
                continue
            try:
                o = json.loads(line)
            except Exception:
                nbad += 1; continue
            if o.get('isMeta') or o.get('isSidechain'):
                continue
            og = o.get('origin')
            if isinstance(og, dict) and og.get('kind') and og['kind'] != 'human':
                continue
            c = (o.get('message') or {}).get('content')
            txt = c if isinstance(c, str) else ' '.join(b.get('text', '') for b in (c or []) if isinstance(b, dict) and b.get('type') == 'text')
            tt = txt.lstrip()
            if not tt:
                continue
            if tt.startswith('[Request interrupted'): bump(k, 'i'); continue
            if tt.startswith(('<command-name>', '/', '<bash-input>')): bump(k, 's'); continue
            if tt.startswith(SKIP): continue
            bump(k, 'm'); bump(k, 'w', len(W.findall(txt)))
            bump(k, 'pw', sum(len(W.findall(x)) for x in PASTE.findall(txt)))
            msgs += 1
    if first and not sub:
        sess.append(dict(p=proj, id=os.path.basename(path)[:-6], first=first, last=last, m=msgs))

rl = [dict(p=k.split('|')[0], h=k.split('|')[1], **v) for k, v in rows.items()]
json.dump(dict(machine=host, generated=datetime.datetime.now(datetime.timezone.utc).isoformat(), files=nfiles, badLines=nbad,
               sessions=sess, rows=rl), open(out, 'w'))
tm = sum(r['m'] for r in rl); tw = sum(r['w'] for r in rl)
print(f'Files: {nfiles}  Sessions: {len(sess)}  Your messages: {tm}  Words: {tw}  Unreadable lines: {nbad}')
print(f'PASS: saved {out} - attach it in the Claude chat' if nfiles and os.path.exists(out) else 'FAIL: nothing saved')
