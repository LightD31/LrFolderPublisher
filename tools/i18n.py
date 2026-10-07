#!/usr/bin/env python3
"""Lists the translatable strings of the plug-in and checks translation files.

    python3 tools/i18n.py list            # key<TAB>English text
    python3 tools/i18n.py check           # every key translated, no stale keys
    python3 tools/i18n.py template LANG   # print a skeleton translation file

Strings are written in the code as T( 'Key', 'English' .. 'more', ... ),
FPText.count( n, 'Key', 'one', 'many' ), T( 'Trig/' .. id, label ) (for the
triggers in FPSettings.lua) and LOC '$$$/FolderPublisher/Key=English' (in
Info.lua).
"""
import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'FolderPublisher.lrplugin')
PREFIX = '$$$/FolderPublisher/'

LIT = r"'(?:[^'\\]|\\.)*'"
CONCAT = r"%s(?:\s*\.\.\s*%s)*" % (LIT, LIT)


def unquote(concat):
    parts = re.findall(LIT, concat)
    out = ''
    for p in parts:
        s = p[1:-1]
        s = s.replace("\\'", "'").replace('\\n', '\n').replace('\\\\', '\\')
        out += s
    return out


def lua_to_zstring(text):
    return text.replace('\n', '^n')


def collect():
    strings = {}
    for path in sorted(glob.glob(os.path.join(ROOT, '*.lua'))):
        src = open(path, encoding='utf-8').read()
        for m in re.finditer(r"\bT\(\s*'([A-Za-z0-9/]+)'\s*,\s*(%s)" % CONCAT, src):
            strings.setdefault(m.group(1), unquote(m.group(2)))
        for m in re.finditer(r"FPText\.count\(\s*[^,]+,\s*'([A-Za-z0-9/]+)'\s*,\s*(%s)\s*,\s*(%s)" % (CONCAT, CONCAT), src):
            strings.setdefault(m.group(1) + '/One', unquote(m.group(2)))
            strings.setdefault(m.group(1) + '/Many', unquote(m.group(3)))
        for m in re.finditer(r"\bline\(\s*[^,()]+,\s*'([A-Za-z0-9/]+)'\s*,\s*(%s)\s*,\s*(%s)" % (CONCAT, CONCAT), src):
            strings.setdefault(m.group(1) + '/One', unquote(m.group(2)))
            strings.setdefault(m.group(1) + '/Many', unquote(m.group(3)))
        for m in re.finditer(r"LOC\s*'\$\$\$/FolderPublisher/([A-Za-z0-9/]+)=((?:[^'\\]|\\.)*)'", src):
            strings.setdefault(m.group(1), m.group(2).replace('^.', '…'))
    settings = open(os.path.join(ROOT, 'FPSettings.lua'), encoding='utf-8').read()
    for m in re.finditer(r"\{\s*id = '(\w+)', label = (%s)" % LIT, settings):
        strings.setdefault('Trig/' + m.group(1), unquote(m.group(2)))
    return strings


def read_translations(lang):
    path = os.path.join(ROOT, 'TranslatedStrings_%s.txt' % lang)
    out = {}
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        line = line.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^"\$\$\$/FolderPublisher/([A-Za-z0-9/]+)=(.*)"$', line)
        if not m:
            sys.exit('%s:%d: malformed line' % (path, n))
        if m.group(1) in out:
            sys.exit('%s:%d: duplicate key %s' % (path, n, m.group(1)))
        out[m.group(1)] = m.group(2)
    return out


def placeholders(text):
    return sorted(set(re.findall(r'\^[1-9]', text)))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    strings = collect()
    if cmd == 'list':
        for k in sorted(strings):
            print('%s\t%s' % (k, lua_to_zstring(strings[k])))
    elif cmd == 'template':
        for k in sorted(strings):
            print('"%s%s=%s"' % (PREFIX, k, lua_to_zstring(strings[k])))
    elif cmd == 'check':
        langs = [os.path.basename(p)[len('TranslatedStrings_'):-4]
                 for p in glob.glob(os.path.join(ROOT, 'TranslatedStrings_*.txt'))]
        problems = []
        for lang in langs:
            tr = read_translations(lang)
            for k in sorted(set(strings) - set(tr)):
                problems.append('%s: missing %s (%s)' % (lang, k, strings[k][:60]))
            for k in sorted(set(tr) - set(strings)):
                problems.append('%s: unused %s' % (lang, k))
            for k in sorted(set(tr) & set(strings)):
                if placeholders(tr[k]) != placeholders(strings[k]):
                    problems.append('%s: placeholders differ in %s' % (lang, k))
        for p in problems:
            print(p)
        print('%d strings, %d language(s), %d problem(s)' % (len(strings), len(langs), len(problems)))
        sys.exit(1 if problems else 0)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
