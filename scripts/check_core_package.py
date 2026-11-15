"""Check Pocket core identity and package references before compilation/upload.

Rules: https://www.analogue.co/developer/docs/openfpga/core-definition-files
       https://www.analogue.co/developer/docs/openfpga/core-definition-files/core-json
"""
import argparse
import json
from pathlib import Path


def check(root, require_bitstream=False):
    manifests = sorted((root / 'Cores').glob('*/core.json'))
    if not manifests:
        raise ValueError(f'No core manifests in {root}')
    for manifest in manifests:
        folder = manifest.parent
        core = json.loads(manifest.read_text(encoding='utf-8'))['core']
        if core['magic'] != 'APF_VER_1':
            raise ValueError(f'{manifest}: invalid magic')
        meta = core['metadata']
        identity = meta['author'] + '.' + meta['shortname']
        if folder.name != identity:
            raise ValueError(f'{folder.name}: folder must match author.shortname: {identity}')
        for key, limit in [('author', 31), ('shortname', 31), ('description', 63),
                           ('url', 63), ('version', 31), ('date_release', 10)]:
            if not isinstance(meta[key], str) or not 0 < len(meta[key]) <= limit:
                raise ValueError(f'{manifest}: invalid {key} length (max {limit})')
        for name in ('audio', 'data', 'input', 'interact', 'variants', 'video'):
            json.loads((folder / (name + '.json')).read_text(encoding='utf-8'))
        for platform in meta['platform_ids']:
            json.loads((root / 'Platforms' / (platform + '.json')).read_text(encoding='utf-8'))
        for name in ('icon.bin', 'info.txt'):
            if not (folder / name).is_file() or not (folder / name).stat().st_size:
                raise ValueError(f'{folder}: missing/empty {name}')
        for entry in core['cores']:
            name = entry['filename']
            if not name or len(name) > 15 or Path(name).name != name:
                raise ValueError(f'{manifest}: invalid bitstream filename: {name}')
            if require_bitstream and (not (folder / name).is_file() or not (folder / name).stat().st_size):
                raise ValueError(f'{folder}: missing/empty bitstream: {name}')
        print(f'Package identity/references OK: {identity}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', type=Path, default=Path(__file__).resolve().parents[1] / 'pkg')
    parser.add_argument('--require-bitstream', action='store_true')
    args = parser.parse_args()
    check(args.root, args.require_bitstream)
