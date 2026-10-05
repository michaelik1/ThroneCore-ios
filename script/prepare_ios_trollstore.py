#!/usr/bin/env python3
"""Add deterministic, code-drawn T icons to the staged developer app."""
import pathlib
import plistlib
import struct
import sys
import zlib

app, root = map(pathlib.Path, sys.argv[1:])


def png(size):
    # Opaque native-resolution artwork; iOS supplies the rounded icon mask.
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            horizontal = .20 <= x / size < .80 and .22 <= y / size < .37
            vertical = .425 <= x / size < .575 and .32 <= y / size < .79
            row.extend((255, 255, 255) if horizontal or vertical else (20, 95, 110))
        rows.append(row)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


for name, size in [('AppIcon60x60@2x.png', 120), ('AppIcon60x60@3x.png', 180),
                   ('AppIcon76x76.png', 76), ('AppIcon76x76@2x.png', 152),
                   ('AppIcon83.5x83.5@2x.png', 167)]:
    (app / name).write_bytes(png(size))
path = app / 'Info.plist'
info = plistlib.loads(path.read_bytes())
info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60'], 'UIPrerenderedIcon': False}}
info['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60', 'AppIcon76x76', 'AppIcon83.5x83.5'], 'UIPrerenderedIcon': False}}
path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
(app / 'TrollStore-INSTALL.txt').write_text((root / 'docs/IOS_TROLLSTORE.md').read_text())

# Match the identity scheme used by TrollStore when it supplies missing identity.
# Keep host/extension identities explicit because an existing NE entitlement means
# TrollStore does not take its no-entitlements fallback path.
for subpath, source, filename in [('', 'Host/Host.entitlements', 'host-entitlements.plist'),
                                ('PlugIns/PacketTunnel.appex', 'PacketTunnel/PacketTunnel.entitlements', 'extension-entitlements.plist')]:
    bundle_info = plistlib.loads((app / subpath / 'Info.plist').read_bytes())
    entitlements = plistlib.loads((root / 'apple/Example' / source).read_bytes())
    entitlements['application-identifier'] = 'TROLLTROLL.' + bundle_info['CFBundleIdentifier']
    entitlements['com.apple.developer.team-identifier'] = 'TROLLTROLL'
    (app.parent.parent / filename).write_bytes(plistlib.dumps(entitlements))
