#!/usr/bin/env python3
"""Read-only static IPA checks, including Mach-O identity and embedded entitlements.

This validates structure, not cryptographic signatures or physical VPN behavior.
The macOS packaging script additionally runs codesign --verify --strict --deep.
"""
import hashlib
import json
import pathlib
import plistlib
import stat
import struct
import sys
import zipfile

TEAM = 'TROLLTROLL'  # Synthetic local identity, not an Apple developer account.
NE = 'com.apple.developer.networking.networkextension'


def check(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    return f'{value >> 16}.{(value >> 8) & 255}.{value & 255}'


def macho(data):
    check(data[:4] == b'\xcf\xfa\xed\xfe', 'Expected a thin little-endian 64-bit Mach-O')
    _, cpu, _, filetype, count, command_bytes, _, _ = struct.unpack_from('<8I', data)
    check(cpu == 0x100000c and filetype == 2, 'Expected arm64 device executable')
    offset, minimum, platform, signature = 32, None, None, None
    check(offset + command_bytes <= len(data), 'Invalid Mach-O load-command bounds')
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        check(size >= 8 and offset + size <= 32 + command_bytes, 'Invalid load command')
        if command == 0x32:
            platform, minimum = struct.unpack_from('<II', data, offset + 8)
        elif command == 0x25:
            platform, minimum = 2, struct.unpack_from('<I', data, offset + 8)[0]
        elif command == 0x1d:
            start, length = struct.unpack_from('<II', data, offset + 8)
            check(start + length <= len(data), 'Invalid signature bounds')
            signature = data[start:start + length]
        elif command in (0x21, 0x2c):
            check(struct.unpack_from('<I', data, offset + 16)[0] == 0, 'Unexpected encrypted binary')
        offset += size
    check(platform == 2, 'Expected iOS device platform, not simulator')
    check(minimum == 0x0f0000, 'Expected iOS 15.0 deployment target')
    check(signature is not None, 'Missing code signature')
    magic, length, slots = struct.unpack_from('>III', signature)
    check(magic == 0xfade0cc0 and length <= len(signature), 'Invalid signature superblob')
    entitlements, ad_hoc, der = None, False, False
    for index in range(slots):
        slot, start = struct.unpack_from('>II', signature, 12 + index * 8)
        blob_magic, blob_length = struct.unpack_from('>II', signature, start)
        check(start + blob_length <= length, 'Invalid signature blob')
        blob = signature[start:start + blob_length]
        if slot == 0:
            check(blob_magic == 0xfade0c02, 'Missing CodeDirectory')
            ad_hoc = bool(struct.unpack_from('>I', blob, 12)[0] & 2)
        elif slot == 5:
            check(blob_magic == 0xfade7171, 'Invalid entitlement blob')
            entitlements = plistlib.loads(blob[8:])
        elif slot == 7:
            der = blob_magic == 0xfade7172
    check(ad_hoc and der and entitlements is not None, 'Missing ad-hoc/XML/DER signature metadata')
    return {'architecture': 'arm64', 'platform': 'iOS', 'minimumOS': version(minimum),
            'adHoc': ad_hoc, 'derEntitlements': der, 'entitlements': entitlements}


def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        check(len(names) == len(set(names)), 'Duplicate ZIP entry')
        check(all(n.startswith('Payload/') and '..' not in pathlib.PurePosixPath(n).parts
                  for n in names), 'Unexpected ZIP root/path')
        check(archive.testzip() is None, 'ZIP CRC failure')
        apps = sorted({n.split('/')[1] for n in names if len(n.split('/')) > 2})
        check(apps == ['ThroneCoreExample.app'], 'Expected exactly one top-level app')
        host = 'Payload/ThroneCoreExample.app/'
        extension = host + 'PlugIns/PacketTunnel.appex/'
        check(not any('.framework/' in n or n.endswith('embedded.mobileprovision') for n in names),
              'Unexpected embedded framework or provisioning profile')
        reports = []
        for prefix, kind in [(host, 'APPL'), (extension, 'XPC!')]:
            info = plistlib.loads(archive.read(prefix + 'Info.plist'))
            check(info['CFBundlePackageType'] == kind, 'Incorrect package type')
            check(info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'Incorrect supported platform')
            check(info['MinimumOSVersion'] == '15.0', 'Incorrect plist minimum iOS')
            identifier = info['CFBundleIdentifier']
            binary = prefix + info['CFBundleExecutable']
            permissions = archive.getinfo(binary).external_attr >> 16
            check(permissions & stat.S_IXUSR, 'Executable permission is missing')
            report = macho(archive.read(binary))
            expected = {NE: ['packet-tunnel-provider'],
                        'application-identifier': TEAM + '.' + identifier,
                        'com.apple.developer.team-identifier': TEAM}
            check(report['entitlements'] == expected, 'Unexpected or missing signing entitlements')
            report.update(bundleIdentifier=identifier, packageType=kind, executable=binary,
                          executableBytes=archive.getinfo(binary).file_size)
            reports.append(report)
            if kind == 'XPC!':
                ne = info['NSExtension']
                check(ne['NSExtensionPointIdentifier'] == 'com.apple.networkextension.packet-tunnel',
                      'Wrong NetworkExtension type')
                check(ne['NSExtensionPrincipalClass'] == 'PacketTunnel.PacketTunnelProvider',
                      'Wrong provider class')
            else:
                check(info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconFiles'] == ['AppIcon60x60'],
                      'Missing iPhone icon declaration')
        check(reports[1]['bundleIdentifier'] == reports[0]['bundleIdentifier'] + '.PacketTunnel',
              'Host and extension IDs do not match')
        for filename, size in [('AppIcon60x60@2x.png', 120), ('AppIcon60x60@3x.png', 180)]:
            data = archive.read(host + filename)
            check(data[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack_from('>II', data, 16) == (size, size),
                  'Invalid native-resolution icon')
        for filename in ['sing-box-direct.json', 'sing-box-xray.json', 'xray-loopback.json']:
            json.loads(archive.read(host + filename))
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return {'file': path.name, 'bytes': path.stat().st_size,
            'sha256': digest.hexdigest(),
            'staticChecks': 'passed', 'physicalDeviceVPN': 'not tested', 'bundles': reports}


if __name__ == '__main__':
    print(json.dumps(verify(pathlib.Path(sys.argv[1])), indent=2))
