#!/usr/bin/env python3
"""Sum up a heapprofd trace (perfetto, android.heapprofd): native memory allocated while the trace
ran and still not freed when it stopped, grouped by the library and function that called malloc.

  python3 tool/heapprofd-summary.py <trace.pftrace> [--top 25] \
      [--symbols base.apk!libflutter.so=<unstripped libflutter.so> --symbolizer <ndk llvm-symbolizer>]

Flutter's engine in the APK is stripped. The unstripped one for the same engine is
storage.googleapis.com/flutter_infra_release/flutter/<bin/internal/engine.version>/android-arm64-profile/symbols.zip
(check `llvm-readelf -n` Build ID matches the libflutter.so in the APK, or the names are garbage).

No trace_processor needed: reads the protobuf wire format directly, only the ProfilePacket fields
heapprofd writes (strings, mappings, frames, callstacks, process_dumps). heapprofd samples, so the
byte counts are its estimates, not exact. Frames inside libc / libc++ / the heapprofd client
(malloc, operator new …) are skipped to find the caller; libraries without symbols (Flutter's
release-stripped engine) show as library+offset.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess

# 分配器自己的一层层包装：找「谁要的内存」时跳过。
ALLOCATOR = re.compile(r'operator new|operator_new|^(dart::)?(malloc|calloc|realloc)\b|sk_malloc|sk_realloc|'
                       r'sk_alloc|SkContainerAllocator|__libcpp_allocate|__allocate_at_least|allocator<|'
                       r'MallocAllocated::operator|^(je_|scudo|malloc)')


def fields(buf):
    """Yield (field number, wire type, value) for one protobuf message; bytes for length-delimited."""
    i, n = 0, len(buf)
    while i < n:
        key, i = varint(buf, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = varint(buf, i)
        elif wire == 1:
            value, i = int.from_bytes(buf[i:i + 8], 'little'), i + 8
        elif wire == 2:
            size, i = varint(buf, i)
            value, i = buf[i:i + size], i + size
        elif wire == 5:
            value, i = int.from_bytes(buf[i:i + 4], 'little'), i + 4
        else:
            raise ValueError(f'wire type {wire} at {i}')
        yield number, wire, value


def varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7f) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def packed(wire, value):
    """repeated uint64: packed (length-delimited) or one varint per field."""
    if wire != 2:
        return [value]
    out, i = [], 0
    while i < len(value):
        v, i = varint(value, i)
        out.append(v)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('trace')
    parser.add_argument('--top', type=int, default=25)
    parser.add_argument('--symbols', action='append', default=[], metavar='LIB=UNSTRIPPED')
    parser.add_argument('--symbolizer', default='llvm-symbolizer')
    args = parser.parse_args()
    data = Path(args.trace).read_bytes()

    # 符号表有两种写法：老版本写在 ProfilePacket 里、共用一张字符串表；Android 11 的 heapprofd 写在
    # TracePacket.interned_data，函数名、库路径各一张表（iid 各算各的）。两种都读。
    strings, function_names, mapping_paths = {}, {}, {}
    mappings, frames, callstacks = {}, {}, {}
    dumps = []
    flags = defaultdict(int)

    def interned_string(v, table):  # InternedString {iid=1, str=2}
        d = {k: val for k, _, val in fields(v)}
        table[d.get(1, 0)] = bytes(d.get(2, b'')).decode('utf-8', 'replace')

    def mapping(v):  # Mapping {iid=1, build_id=2, start=4, end=5, path_string_ids=7}
        m = {'paths': []}
        for k, kw, val in fields(v):
            if k == 7:
                m['paths'] += packed(kw, val)
            else:
                m[k] = val
        mappings[m.get(1, 0)] = m

    def frame(v):  # Frame {iid=1, function_name_id=2, mapping_id=3, rel_pc=4}
        d = {k: val for k, _, val in fields(v)}
        frames[d.get(1, 0)] = d

    def callstack(v):  # Callstack {iid=1, frame_ids=2} (outermost frame first)
        ids, iid = [], 0
        for k, kw, val in fields(v):
            if k == 1:
                iid = val
            elif k == 2:
                ids += packed(kw, val)
        callstacks[iid] = ids

    for number, _, packet in fields(data):
        if number != 1:  # Trace.packet
            continue
        for pnumber, _, profile in fields(packet):
            if pnumber == 12:  # TracePacket.interned_data
                for f, w, v in fields(profile):
                    if f == 5:
                        interned_string(v, function_names)
                    elif f == 17:
                        interned_string(v, mapping_paths)
                    elif f == 19:
                        mapping(v)
                    elif f == 6:
                        frame(v)
                    elif f == 7:
                        callstack(v)
                continue
            if pnumber != 37:  # TracePacket.profile_packet
                continue
            for f, w, v in fields(profile):
                if f == 1:
                    interned_string(v, strings)
                elif f == 4:
                    mapping(v)
                elif f == 2:
                    frame(v)
                elif f == 3:
                    callstack(v)
                elif f == 5:  # ProcessHeapSamples
                    dump = {'samples': []}
                    for k, kw, val in fields(v):
                        if k == 2:  # HeapSample {callstack_id=1, self_allocated=2, self_freed=3, alloc_count=5, free_count=6}
                            s = {sk: sv for sk, _, sv in fields(val)}
                            dump['samples'].append(s)
                        elif k in (3, 4, 6, 7, 8, 14) and val:
                            flags[{3: 'from_startup', 4: 'rejected_concurrent', 6: 'disconnected',
                                   7: 'buffer_overran', 8: 'buffer_corrupted', 14: 'hit_guardrail'}[k]] += 1
                        elif kw != 2:
                            dump[k] = val
                        elif k == 11:
                            dump['heap'] = bytes(val).decode()
                    dumps.append(dump)

    def mapping_name(mid):
        m = mappings.get(mid)
        if not m:
            return '?'
        path = '/'.join(mapping_paths.get(p) or strings.get(p, '?') for p in m['paths'])
        return path.rsplit('/', 1)[-1] or path

    skip = ('libc.so', 'libc++.so', 'libc++_shared.so', 'libheapprofd_client.so',
            'libheapprofd_client_api.so', 'libdl.so', 'linker64')

    # 给没名字的帧查符号：一个地址可能展开成几层内联函数（最里层在前）。
    symbolized = {}

    def own_name(fr):  # 没名字的帧也可能带着 function_name_id，指向空串
        if not fr.get(2):
            return None
        return function_names.get(fr.get(2)) or strings.get(fr.get(2)) or None

    for spec in args.symbols:
        lib, path = spec.split('=', 1)
        pcs = sorted({fr.get(4, 0) for fr in frames.values()
                      if mapping_name(fr.get(3)) == lib and not own_name(fr)})
        if not pcs:
            continue
        result = subprocess.run([args.symbolizer, f'--obj={path}', '--output-style=JSON'],
                                input='\n'.join(f'{pc:#x}' for pc in pcs), capture_output=True,
                                text=True, check=True)
        for line in result.stdout.splitlines():
            for entry in json.loads(line) if line.startswith('[') else [json.loads(line)]:
                names = [s['FunctionName'] for s in entry.get('Symbol', []) if s.get('FunctionName')]
                if names:
                    symbolized[(lib, int(entry['Address'], 16))] = names

    def describe(fid):
        """[(lib, function)] for one frame, outermost inline level first."""
        fr = frames.get(fid, {})
        lib = mapping_name(fr.get(3))
        fn = own_name(fr)
        if fn:
            return [(lib, fn)]
        names = symbolized.get((lib, fr.get(4, 0)))
        if names:
            return [(lib, name) for name in reversed(names)]
        return [(lib, f'+{fr.get(4, 0):#x}')]

    print(f'strings={len(strings)} functionNames={len(function_names)} '
          f'mappingPaths={len(mapping_paths)} mappings={len(mappings)} frames={len(frames)} '
          f'callstacks={len(callstacks)} dumps={len(dumps)} flags={dict(flags)}')
    if not dumps:
        print('no ProcessHeapSamples: heapprofd did not attach or wrote nothing')
        return 1
    # heapprofd writes one dump per heap at the end (and more with continuous dumps); take the last per pid+heap.
    last = {}
    for d in dumps:
        last[(d.get(1), d.get('heap', 'libc.malloc'))] = d
    for (pid, heap), dump in last.items():
        by_lib, by_caller, by_stack = defaultdict(int), defaultdict(int), defaultdict(int)
        total_alloc = total_unfreed = 0
        for s in dump['samples']:
            unfreed = s.get(2, 0) - s.get(3, 0)
            total_alloc += s.get(2, 0)
            total_unfreed += unfreed
            if unfreed <= 0:
                continue
            stack = [f for fid in callstacks.get(s.get(1), []) for f in describe(fid)]
            inner = [fr for fr in reversed(stack)
                     if fr[0] not in skip and not ALLOCATOR.search(fr[1])]
            caller = inner[0] if inner else ('?', '?')
            by_lib[caller[0]] += unfreed
            by_caller[(caller[0], ' < '.join(fn for _, fn in inner[:3]))] += unfreed
            by_stack[tuple(inner[:12])] += unfreed
        print(f'\npid={pid} heap={heap} interval={dump.get(12)} samples={len(dump["samples"])} '
              f'allocated={total_alloc // 1024} KiB unfreed={total_unfreed // 1024} KiB')
        print('unfreed by library of the first non-allocator frame:')
        for lib, size in sorted(by_lib.items(), key=lambda kv: -kv[1])[:args.top]:
            print(f'  {size // 1024:>8} KiB  {lib}')
        print('unfreed by caller:')
        for (lib, fn), size in sorted(by_caller.items(), key=lambda kv: -kv[1])[:args.top]:
            print(f'  {size // 1024:>8} KiB  {lib} {fn}')
        print('largest unfreed stacks (innermost first, 12 frames):')
        for stack, size in sorted(by_stack.items(), key=lambda kv: -kv[1])[:10]:
            print(f'  {size // 1024:>8} KiB')
            for lib, fn in stack:
                print(f'             {lib} {fn}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
