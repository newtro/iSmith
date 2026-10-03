#!/usr/bin/env python3
"""Adds a release to iSmith's Sparkle appcast, newest first. Used by Tools/release.sh.

  appcast.py appcast.xml --version 1.0.1 --build 57 --min-os 14.0 --url URL \
      --signature 'sparkle:edSignature="…" length="…"' --notes URL
"""
import argparse
import email.utils
import os
import re
import sys
from xml.sax.saxutils import escape

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>iSmith</title>
    <link>https://github.com/newtro/iSmith</link>
    <description>iSmith updates</description>
    <language>en</language>
"""
FOOTER = """  </channel>
</rss>
"""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("appcast")
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--min-os", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--notes", required=True)
    a = p.parse_args()

    sig = re.search(r'sparkle:edSignature="([^"]+)"', a.signature)
    length = re.search(r'length="(\d+)"', a.signature)
    if not sig or not length:
        sys.exit(f"Unexpected sign_update output: {a.signature!r}")

    items = ""
    if os.path.exists(a.appcast):
        text = open(a.appcast, encoding="utf-8").read()
        if f"<sparkle:version>{a.build}</sparkle:version>" in text:
            sys.exit(f"Build {a.build} is already in {a.appcast}")
        items = "".join(re.findall(r"    <item>.*?</item>\n", text, flags=re.S))

    item = f"""    <item>
      <title>Version {escape(a.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(a.min_os)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(a.notes)}</sparkle:releaseNotesLink>
      <enclosure url="{escape(a.url)}" type="application/octet-stream" sparkle:edSignature="{sig.group(1)}" length="{length.group(1)}"/>
    </item>
"""
    with open(a.appcast, "w", encoding="utf-8") as f:
        f.write(HEADER + item + items + FOOTER)
    print(f"Added {a.version} ({a.build}) to {a.appcast}")


if __name__ == "__main__":
    main()
