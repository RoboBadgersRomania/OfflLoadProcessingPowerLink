#!/usr/bin/env python3
"""Hardware check: short tests that PROVE this powerplant has the hardware it reports.

Runs inside the ROS dev container (power.sh hwcheck pipes it in), ~15 seconds, standard library only:
  * GPU  - asks the NVIDIA driver directly (CUDA driver API via ctypes): name, total memory, then
           really ALLOCATES ~85 % of that memory and times a host->GPU copy. A fake/renamed GPU or
           "24 GB" that isn't there fails here.
  * CPU  - SHA-256 throughput on 1 thread and on all threads (real cores scale, fake counts don't).
  * RAM  - allocates and writes a block of memory and times it.
Prints one JSON object with every number and a verdict. It can't stop an owner with root access from
lying on purpose (that needs remote attestation); it catches wrong specs, missing VRAM and broken GPUs.
"""
import ctypes
import hashlib
import json
import multiprocessing as mp
import os
import subprocess
import time


def sha_bench(seconds=1.0):
    data = b'\x5a' * 65536
    n, t0 = 0, time.perf_counter()
    while time.perf_counter() - t0 < seconds:
        hashlib.sha256(data).digest()
        n += 1
    return n * 65536 / (time.perf_counter() - t0) / 1e6      # MB/s


def cpu_test():
    threads = os.cpu_count() or 1
    single = sha_bench(1.0)
    with mp.Pool(threads) as pool:
        total = sum(pool.map(sha_bench, [1.5] * threads))
    scaling = total / single if single else 0
    # real hardware: >= ~0.45 x threads (hyper-threads add less than full cores)
    return {'threads': threads, 'sha256_mb_s_1thread': round(single), 'sha256_mb_s_all': round(total),
            'scaling': round(scaling, 1), 'ok': scaling >= max(1.0, 0.45 * threads)}


def ram_test():
    avail_kb = 0
    for line in open('/proc/meminfo'):
        if line.startswith('MemAvailable'):
            avail_kb = int(line.split()[1])
    size = int(min(4 * 1024**3, avail_kb * 1024 * 0.25))
    t0 = time.perf_counter()
    try:
        buf = bytearray(size)
        for i in range(0, size, 4096):          # touch every page so it's really backed by RAM
            buf[i] = 1
        secs = time.perf_counter() - t0
        del buf
        return {'tested_gb': round(size / 1024**3, 1), 'write_gb_s': round(size / 1024**3 / secs, 1), 'ok': True}
    except MemoryError:
        return {'tested_gb': round(size / 1024**3, 1), 'ok': False, 'error': 'allocation failed'}


def gpu_test():
    out = {'ok': False}
    try:
        smi = subprocess.run(['nvidia-smi', '--query-gpu=name,memory.total', '--format=csv,noheader,nounits'],
                             capture_output=True, text=True, timeout=20).stdout.strip().split('\n')[0]
        out['smi_name'], out['smi_total_mb'] = smi.split(',')[0].strip(), int(smi.split(',')[1])
    except Exception as e:
        out['error'] = f'nvidia-smi: {e}'
        return out
    try:
        cu = ctypes.CDLL('libcuda.so.1')
    except OSError as e:
        out['error'] = f'no CUDA driver in the container ({e})'
        return out

    def check(rc, what):
        if rc != 0:
            raise RuntimeError(f'{what} failed (CUDA error {rc})')
    dev, ctx = ctypes.c_int(), ctypes.c_void_p()
    name, total = ctypes.create_string_buffer(256), ctypes.c_size_t()
    check(cu.cuInit(0), 'cuInit')
    check(cu.cuDeviceGet(ctypes.byref(dev), 0), 'cuDeviceGet')
    check(cu.cuDeviceGetName(name, 256, dev), 'cuDeviceGetName')
    check(cu.cuDeviceTotalMem_v2(ctypes.byref(total), dev), 'cuDeviceTotalMem')
    check(cu.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev), 'cuCtxCreate')
    out['cuda_name'] = name.value.decode()
    out['cuda_total_mb'] = total.value // 1024**2
    chunk = 256 * 1024**2
    ptrs = []
    try:
        free, tot = ctypes.c_size_t(), ctypes.c_size_t()
        cu.cuMemGetInfo_v2(ctypes.byref(free), ctypes.byref(tot))
        target = int(free.value * 0.85)
        while len(ptrs) * chunk < target:
            p = ctypes.c_uint64()
            if cu.cuMemAlloc_v2(ctypes.byref(p), chunk) != 0:
                break
            ptrs.append(p)
        out['allocated_mb'] = len(ptrs) * chunk // 1024**2
        out['free_before_mb'] = free.value // 1024**2
        if ptrs:
            host = ctypes.create_string_buffer(chunk)
            t0 = time.perf_counter()
            for _ in range(4):
                check(cu.cuMemcpyHtoD_v2(ptrs[0], host, chunk), 'cuMemcpyHtoD')
            cu.cuCtxSynchronize()
            out['copy_gb_s'] = round(4 * chunk / 1024**3 / (time.perf_counter() - t0), 1)
    finally:
        for p in ptrs:
            cu.cuMemFree_v2(p)
        cu.cuCtxDestroy_v2(ctx)
    used_by_others = out['smi_total_mb'] - out['free_before_mb']
    out['ok'] = (out['cuda_name'] == out['smi_name']
                 and abs(out['cuda_total_mb'] - out['smi_total_mb']) < 512
                 and out['allocated_mb'] >= 0.8 * (out['smi_total_mb'] - used_by_others) - 512)
    return out


def main():
    t0 = time.time()
    res = {'time': int(t0)}
    for key, fn in (('gpu', gpu_test), ('cpu', cpu_test), ('ram', ram_test)):
        try:
            res[key] = fn()
        except Exception as e:
            res[key] = {'ok': False, 'error': str(e)}
    res['seconds'] = round(time.time() - t0, 1)
    res['verified'] = all(res[k].get('ok') for k in ('gpu', 'cpu', 'ram'))
    g = res['gpu']
    res['summary'] = (f"{'VERIFIED' if res['verified'] else 'NOT VERIFIED'}: "
                      f"GPU {g.get('cuda_name', '?')} {g.get('allocated_mb', 0) / 1024:.1f} GB VRAM allocated"
                      f" ({g.get('copy_gb_s', '?')} GB/s), CPU {res['cpu'].get('threads')} threads x{res['cpu'].get('scaling')},"
                      f" RAM {res['ram'].get('tested_gb')} GB at {res['ram'].get('write_gb_s', '?')} GB/s")
    print(json.dumps(res))


if __name__ == '__main__':
    main()
