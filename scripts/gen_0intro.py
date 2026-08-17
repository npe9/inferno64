import os, re, sys

def parse_name(text):
    m = re.search(r'\.SH NAME\s*\n(.*?)(?=\.SH |\Z)', text, re.DOTALL)
    if not m:
        return None, None
    raw = m.group(1).strip()
    parts = re.split(r'\\-', raw, maxsplit=1)
    if len(parts) != 2:
        return None, None
    names_raw, desc = parts
    names_raw = re.sub(r'^\.[^\n]*\n?', '', names_raw, flags=re.MULTILINE)
    desc = re.sub(r'^\.[^\n]*\n?', '', desc, flags=re.MULTILINE)
    desc = re.sub(r'\s+', ' ', desc).strip()
    names = [n.strip() for n in re.split(r'[,\s]+', names_raw) if n.strip()]
    return names, desc

by_page = {}
for f in sorted(os.listdir('man/1')):
    if f in ('INDEX', '0intro'):
        continue
    path = 'man/1/' + f
    if not os.path.isfile(path):
        continue
    try:
        text = open(path).read()
    except Exception:
        continue
    names, desc = parse_name(text)
    if names and desc:
        by_page[f] = (names, desc)

rows = []
for page, (names, desc) in by_page.items():
    primary = names[0]
    rows.append((primary.lower(), primary, page, desc))
rows.sort()

out = []
out.append('.TH INTRO 1')
out.append('.SH NAME')
out.append('intro \\- introduction to section 1 and index of commands')
out.append('.SH DESCRIPTION')
out.append('.PP')
out.append('Section 1 of the Inferno manual covers commands and applications.')
out.append('For a general introduction to Inferno see')
out.append('.IR intro (1).')
out.append('.PP')
out.append('Commands whose names begin with')
out.append('.B wm/')
out.append('run under the window manager')
out.append('.IR wm (1)')
out.append('and require a display context.')
out.append('.SS Commands')
out.append('.TP 5')
for _, primary, page, desc in rows:
    if len(desc) > 64:
        desc = desc[:61] + '...'
    desc = desc.replace('\\', '\\\\')
    out.append('.TP')
    out.append('.IR ' + primary + ' (1)')
    out.append(desc)
out.append('.SH SEE ALSO')
out.append(r'.IR intro (2) ,')
out.append(r'.IR intro (3) ,')
out.append(r'.IR intro (4) ,')
out.append(r'.IR intro (5) ,')
out.append(r'.IR intro (6) ,')
out.append(r'.IR intro (8) ,')
out.append(r'.IR intro (9) ,')
out.append(r'.IR intro (10)')
print('\n'.join(out))
