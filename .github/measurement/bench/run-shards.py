#!/usr/bin/env python3
"""Run upstream Chainsaw jobs against fresh substrate-G clones on one worker.

This is the provisioning replacement arm: one Chainsaw invocation per shard.
Prepared snapshots are reused on this worker; every shard gets a fresh clone.
"""
import argparse
import collections
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--kyverno', type=Path, required=True)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--jobs', default='policy-validation', help='comma-separated job IDs, run sequentially')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--repetitions', type=int, default=1)
    args = p.parse_args()
    bundle, kyverno, out = args.bundle.resolve(), args.kyverno.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    manifest = json.loads(args.manifest.read_text())
    jobs = {j['id']: j for j in manifest['jobs']}
    selected = [jobs[j] for j in args.jobs.split(',')]
    if args.repetitions < 1:
        p.error('--repetitions must be positive')
    # Refuse unsupported installs before doing any work; extend explicitly when
    # those capabilities are packaged. Never silently substitute a standard job.
    for job in selected:
        for key in ('install_cert_manager', 'install_kubectl_evict', 'install_openreports'):
            if job[key] != 'false':
                p.error(f"{job['id']}: {key} is not packaged yet")
        if job['explicit_install_settings'] or job['kind_config'] != './scripts/config/kind/default.yaml':
            p.error(f"{job['id']}: custom cluster/install settings require a separate adapter")
    actual = subprocess.check_output(['git', '-C', str(kyverno), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != manifest['source_commit']:
        p.error(f'Kyverno checkout {actual} differs from manifest {manifest["source_commit"]}')
    env = os.environ.copy()
    env.update(HARNESS_ARTIFACT_DIR=str(out / 'runtime'),
               HARNESS_SNAPSHOT_CACHE=str(out / 'snapshots'),
               HARNESS_ASSET_CACHE=str(bundle / 'cache' / 'assets'),
               HARNESS_FIRECRACKER=str(bundle / 'bin' / 'firecracker'),
               PATH=str(bundle / 'bin') + os.pathsep + env['PATH'])
    # This pin is part of the checksum-verified bundle, not inferred from a guest
    # that has already booted. It also identifies the source-free cache keys.
    env['HARNESS_GUEST_BUILD_FINGERPRINT'] = (bundle / 'guest-build-fingerprint').read_text().strip()
    # A scrubbed bundle ships its own guest instead of a pinned asset.
    # The harness boots a local guest only when HARNESS_ARTIFACT_DIR holds it,
    # and otherwise falls back to the pinned registry asset, so stage it there
    # and refuse a bundle whose provenance promises a local guest it lacks.
    local_guest = [bundle / 'artifacts' / n for n in ('vmlinux', 'initramfs.cpio.gz')]
    provenance = json.loads((bundle / 'provenance.json').read_text())
    if provenance.get('guest') == 'local':
        if not all(f.is_file() for f in local_guest):
            p.error('bundle provenance says guest=local but artifacts/ lacks vmlinux or initramfs.cpio.gz')
        (out / 'runtime').mkdir(parents=True, exist_ok=True)
        for src in local_guest:
            (out / 'runtime' / src.name).symlink_to(src.resolve())
    (out / 'selection.json').write_text(json.dumps(selected, indent=2) + '\n')
    failed = False

    def phase(name, start, code, **fields):
        row = dict(phase=name, start_unix_ns=start, end_unix_ns=time.time_ns(), exit_code=code, **fields)
        with (out / 'phases.jsonl').open('a') as f:
            f.write(json.dumps(row) + '\n')
        print(json.dumps(row), flush=True)

    for rep in range(1, args.repetitions + 1):
        for job in selected:
            dest = out / f"{job['id']}-r{rep}"
            dest.mkdir()
            env['HARNESS_TIMING_JSONL'] = str(dest / 'harness-phases.jsonl')
            kubeconfig = dest / 'kubeconfig'
            start = time.time_ns()
            proc = None
            try:
                with (dest / 'provision.log').open('w') as log:
                    cmd = [str(bundle / 'bin' / 'p82-sweep'), '-kyverno', str(kyverno),
                           '-sut', str(bundle / 'artifacts' / 'sut' / 'kyverno-admission'),
                           '-controllers', 'all', '-install-ns', 'kyverno', '-upstream-ci',
                           '-upstream-configs', job['kyverno_configs'], '-hold',
                           '-kubeconfig-out', str(kubeconfig)]
                    proc = subprocess.Popen(cmd, cwd=bundle, env=env, stdout=log, stderr=subprocess.STDOUT)
                    deadline = time.monotonic() + 600
                    while not kubeconfig.exists():
                        if proc.poll() is not None:
                            raise RuntimeError(f'provision exited {proc.returncode}: {log.name}')
                        if time.monotonic() > deadline:
                            raise TimeoutError('provision did not publish kubeconfig within 10 minutes')
                        time.sleep(0.2)
                    phase('provision', start, 0, job=job['id'], repetition=rep)
                    testenv = env | {'KUBECONFIG': str(kubeconfig)}
                    version = subprocess.check_output(['kubectl', 'version', '-o', 'json'], env=testenv, text=True)
                    (dest / 'kubernetes-version.json').write_text(version)
                    # Run quarantine edits on a scratch test tree, preserving the
                    # pinned checkout and the baseline config input bytes.
                    scratch = dest / 'chainsaw'
                    shutil.copytree(kyverno / 'test' / 'conformance' / 'chainsaw', scratch)
                    group = scratch / job['tests_path']
                    for name in filter(None, job['quarantined_tests'].split(',')):
                        for path in group.rglob(name):
                            test = path / 'chainsaw-test.yaml'
                            if path.is_dir() and test.is_file():
                                subprocess.run(['yq', 'eval', '.spec.skip = true', '-i', str(test)], check=True)
                    cmd = ['chainsaw', 'test', '--config', '.chainsaw.yaml',
                           '--include-test-regex', '^chainsaw$/' + job['chainsaw_tests'],
                           '--shard-index', str(job['shard_index']), '--shard-count', str(job['shard_count']),
                           '--report-format', 'JSON', '--report-path', str(dest), '--report-name', 'chainsaw-report']
                    (dest / 'command.json').write_text(json.dumps(cmd) + '\n')
                    start = time.time_ns()
                    with (dest / 'chainsaw.log').open('w') as testlog:
                        result = subprocess.run(cmd, cwd=group, env=testenv, stdout=testlog,
                                                stderr=subprocess.STDOUT, timeout=900)
                    phase('chainsaw', start, result.returncode, job=job['id'], repetition=rep)
                    report = json.loads((dest / 'chainsaw-report.json').read_text())
                    tests = report['tests']
                    counts = collections.Counter(test_status(t) for t in tests)
                    printed = printed_summary(dest / 'chainsaw.log')
                    ok = (result.returncode == 0 and len(tests) == job['selected_directories']
                          and counts['passed'] == len(tests) and printed == dict(counts))
                    summary = dict(job=job['id'], repetition=rep, expected=job['selected_directories'],
                                   reported=len(tests), statuses=dict(counts), printed=printed,
                                   all_passed=ok)
                    (dest / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                    print(json.dumps(summary), flush=True)
                    failed |= not ok
            except Exception as exc:
                failed = True
                (dest / 'error.txt').write_text(str(exc) + '\n')
                print(f"{job['id']}: {exc}", flush=True)
            finally:
                start = time.time_ns()
                if proc is not None and proc.poll() is None:
                    proc.send_signal(signal.SIGTERM)
                    try:
                        proc.wait(timeout=60)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                        failed = True
                dispose_code = proc.returncode if proc else 1
                failed |= dispose_code != 0
                phase('dispose', start, dispose_code, job=job['id'], repetition=rep)
                kubeconfig.unlink(missing_ok=True)
    raise SystemExit(1 if failed else 0)


def test_status(test):
    """Classify one test from Chainsaw's JSON report.

    v0.2.15's report has no per-test status field: a skipped test carries
    `skipped`, a failed one a `failure` on some operation, and a pass neither.
    """
    if test.get('skipped'):
        return 'skipped'

    def failed(node):
        if isinstance(node, dict):
            return bool(node.get('failure')) or any(failed(v) for v in node.values())
        if isinstance(node, list):
            return any(failed(v) for v in node)
        return False
    return 'failed' if failed(test) else 'passed'


def printed_summary(log):
    """Chainsaw's own printed totals, the cross-check for test_status."""
    counts = {}
    for line in log.read_text(errors='replace').splitlines():
        m = re.match(r'- (Passed|Failed|Skipped)\s+tests (\d+)', line)
        if m and int(m.group(2)):
            counts[m.group(1).lower()] = int(m.group(2))
    return counts


if __name__ == '__main__':
    main()
