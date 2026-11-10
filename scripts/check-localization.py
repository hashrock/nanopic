#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""訳のカタログ（Resources/*.xcstrings）と Swift 側の文言のずれを見張る。

    scripts/check-localization.py          ずれていたら 1 で落ちる
    scripts/check-localization.py --quiet  問題があるときだけ出す

なぜ要るか。SwiftPM でビルドしているので、Xcode のように文言を拾ってカタログへ足してくれるものがない。
文言を足して訳を入れ忘れると、英語の画面に日本語がそのまま出る。ここで機械的に見る
（テストの LocalizationTests から走る）。

見るもの:
  1. 画面に出すソース（下の SOURCES）にある日本語の文字列リテラルが、どれもカタログにあるか。
     訳さないもの・保存する名前は、その行に印を付けて外す:
       // l10n:skip    訳さない（開発用の表示など）
       // l10n:stored  日本語のまま保存する名前（出すときに LName で訳す。Sources/NanopicCore/Localized.swift）
  2. LA("…")（エージェント連携の画面）は Agent の表に、それ以外は Localizable か Names の表にあるか。
     Agent の表は App Store 用のアプリに入れないので、取り違えると App Store 版で訳が出ない。
  3. Localizable・Names（App Store 用にも入る表）に MCP・エージェントの文言が混ざっていないか。
  4. どのキーにも英語の訳が付いていて、state が translated か。
  5. 訳の書式指定子（%@ や %lld）がキーと食い違っていないか。
  6. カタログにあるのに Swift 側に見当たらないキー（警告どまり）。

カタログにあることまでしか見ない。その文言が実際に訳を引く形で使われているか（Text("…") のリテラルか、
L("…") で包んであるか）は見ていないので、String の変数に入れてから渡す文言は L() で包むこと。
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, 'Resources')
# 表の名前 → カタログ。Agent は直接配布版だけに入れる（scripts/build-app.sh）
CATALOGS = {name: os.path.join(RESOURCES, name + '.xcstrings')
            for name in ('Localizable', 'Names', 'Agent')}
APPSTORE_TABLES = ('Localizable', 'Names')

# 画面に出す文言のあるソース
SOURCES = ['Sources/Nanopic', 'Sources/NanopicCore', 'Sources/NanopicUI', 'iPad/Nanopic']
# エージェント（MCP）に返す文は訳さない。これらのファイルは LA("…") / L("…") で包んだものだけを見る
WRAPPED_ONLY = {
    'Sources/Nanopic/Agent/AppToolSchemas.swift',
    'Sources/Nanopic/Agent/AgentIntegration.swift',
    'Sources/Nanopic/Agent/MCPServer.swift',
}
# 開発用の性能の計測。訳さない
SKIPPED = {'iPad/Nanopic/PerfMonitor.swift'}

# 日本語の文字（かな・漢字・句読点・全角の記号）
JAPANESE = re.compile(r'[\u3001\u3002\u3040-\u30ff\u3400-\u9fff\uff00-\uffef]')
# 埋め込みも書式指定子も同じ印に潰して突き合わせる。`"\(n) 個"` が `%lld 個` になるのか `%@ 個` になるのかは
# 埋め込む値の型で決まり、ここからは見えないため
HOLE = '\x00'
SPECIFIER = re.compile(r'%(?:\d+\$)?(?:lld|[@dioux]|[+]?\.?\d*l?[fgeEs])')
INTERPOLATION = re.compile(r'(?<!\\)\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)')
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\\((?:[^()"]|\((?:[^()"]|\([^()"]*\))*\))*\)|\\.)*"')
WRAPPED = re.compile(r'\b(LA|L|LFormat|LName)\(\s*("(?:[^"\\\n]|\\\((?:[^()"]|\((?:[^()"]|\([^()"]*\))*\))*\)|\\.)*")')
APPSTORE_FORBIDDEN = re.compile(r'MCP|エージェント|agent', re.IGNORECASE)


def punch(text):
    """キーと Swift のリテラルを、突き合わせられる同じ形にする（%% は % に戻す）"""
    return INTERPOLATION.sub(HOLE, SPECIFIER.sub(HOLE, text.replace('%%', '%')))


def unescape(literal):
    """Swift のリテラル表記を、カタログに入っている素の文字列へ戻す（埋め込みはそのまま残す）"""
    body = literal[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == '\\' and i + 1 < len(body):
            nxt = body[i + 1]
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'"}.get(nxt, '\\' + nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def translation_values(localization):
    """訳文と state を集める。複数形（variations.plural）で分けてあるものは、その全部"""
    found = []

    def walk(node):
        if not isinstance(node, dict):
            return
        unit = node.get('stringUnit')
        if isinstance(unit, dict):
            found.append((unit.get('value', ''), unit.get('state')))
        for child in (node.get('variations') or {}).values():
            for grandchild in (child or {}).values():
                walk(grandchild)

    walk(localization)
    return found


def swift_files():
    for base in SOURCES:
        for dirpath, _, names in os.walk(os.path.join(ROOT, base)):
            for name in sorted(names):
                if name.endswith('.swift'):
                    path = os.path.join(dirpath, name)
                    yield path, os.path.relpath(path, ROOT)


def literals():
    """(ファイル, 行, リテラル, LA で包んであるか) を返す。見るのは日本語の入ったリテラルだけ"""
    for path, rel in swift_files():
        if rel in SKIPPED:
            continue
        for number, line in enumerate(open(path, encoding='utf-8'), 1):
            if line.lstrip().startswith('//') or 'l10n:skip' in line or 'l10n:stored' in line:
                continue
            agent = {m.group(2) for m in WRAPPED.finditer(line) if m.group(1) == 'LA'}
            if rel in WRAPPED_ONLY:
                found = [m.group(2) for m in WRAPPED.finditer(line)]
            else:
                found = [m.group() for m in STRING_LITERAL.finditer(line)]
            for literal in found:
                if JAPANESE.search(INTERPOLATION.sub('', literal)):
                    yield rel, number, literal, literal in agent


def main():
    quiet = '--quiet' in sys.argv
    errors, warnings = [], []
    tables = {}
    for name, path in CATALOGS.items():
        catalog = json.load(open(path, encoding='utf-8'))
        if catalog.get('sourceLanguage') != 'ja':
            errors.append('%s: sourceLanguage が ja ではありません' % name)
        tables[name] = catalog['strings']

    shapes = {name: {punch(key) for key in strings} for name, strings in tables.items()}

    # 1 と 2. リテラルがカタログにあるか
    seen = set()
    for rel, number, literal, agent in literals():
        shape = punch(unescape(literal))
        seen.add(shape)
        if agent:
            if shape not in shapes['Agent']:
                errors.append('%s:%d  LA(%s) が Agent の表にありません' % (rel, number, literal))
        elif shape not in shapes['Localizable'] and shape not in shapes['Names']:
            where = '（Agent の表にはあります。LA() で包むか、表を移してください）' if shape in shapes['Agent'] else ''
            errors.append('%s:%d  %s がカタログにありません%s' % (rel, number, literal, where))

    # 日本語の入っていない文言（"\(名前)..." など）も、L() で包んであれば使っているものとして数える
    for path, rel in swift_files():
        for line in open(path, encoding='utf-8'):
            seen.update(punch(unescape(m.group(2))) for m in WRAPPED.finditer(line))

    # 3. App Store 用にも入る表に MCP の文言が無いか
    for name in APPSTORE_TABLES:
        for key, entry in tables[name].items():
            texts = [key] + [v for v, _ in translation_values((entry.get('localizations') or {}).get('en'))]
            if any(APPSTORE_FORBIDDEN.search(t) for t in texts):
                errors.append('%s の表に MCP・エージェントの文言があります（App Store 用にも入る表）: %r' % (name, key))

    # 4 と 5. 訳の抜けと、書式指定子の食い違い
    for name, strings in tables.items():
        for key in sorted(strings):
            values = translation_values((strings[key].get('localizations') or {}).get('en'))
            if not values or not all(value for value, _ in values):
                errors.append('%s: en の訳がありません: %r' % (name, key))
                continue
            expected = sorted(re.sub(r'\d+\$', '', s) for s in SPECIFIER.findall(key.replace('%%', '')))
            for value, state in values:
                if state != 'translated':
                    errors.append('%s: en の訳が未確定 (%s) です: %r' % (name, state, key))
                actual = sorted(re.sub(r'\d+\$', '', s) for s in SPECIFIER.findall(value.replace('%%', '')))
                if expected != actual:
                    errors.append('%s: en の書式指定子がキーと違います: %r -> %r' % (name, key, value))
                if key.replace('%%', '').count('%') != value.replace('%%', '').count('%'):
                    errors.append('%s: en の %% の数がキーと違います（%% は %%%% と書く）: %r -> %r' % (name, key, value))

    # 6. 使われていないかもしれないキー（Names は保存する名前なので、リテラルと形が合わないものがある）
    for name in ('Localizable', 'Agent'):
        for key in sorted(tables[name]):
            if punch(key) not in seen:
                warnings.append('%s: Swift 側に見当たりません: %r' % (name, key))

    if not quiet:
        for warning in warnings:
            print('警告: ' + warning)
    for error in errors:
        print('エラー: ' + error, file=sys.stderr)
    if errors:
        print('\nカタログと合っていない箇所が %d 件あります。' % len(errors), file=sys.stderr)
        return 1
    if not quiet:
        print('カタログ: %s / 未確認 %d 件'
              % (' / '.join('%s %d' % (n, len(s)) for n, s in tables.items()), len(warnings)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
