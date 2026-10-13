# KLBurn dedicated NAS Runner and build VM

## Current ISO delivery evidence (2026-10-13)

Version1.10.7, clean source/tag `c4f3b8b`: paired full/mem ISO files copied to
Mac `out/`, both sizes and SHA256 values verified after transfer. Build-VM
source2052/root-disk11 and Runner mutation135 passed (clean mutation baseline).
Full firmware51/smoke10/disk-stress32; mem firmware54/retry-smoke22 passed.
Real full-ISO keyboard0/root Shell/exit7/menu/re-entry and no report directory
verified; scope, CPU/memory, disk and final screenshots inspected.

The initial mem smoke was interrupted by a confirmed NAS memory-cgroup OOM
killing this build VM; original logs are retained, not converted to PASS.
Same ISO retried without rebuild: full nested QEMU4096MiB, mem retry2048MiB.
Initial VM live3072MiB, hypervisor limit1536MiB; recovery VM live2048MiB,
hypervisor limit2304MiB; temporary guest swap3072MiB. Build/full stage cgroup
2400MiB, recovery mem1500MiB. These are resource-limited software acceptance,
not performance or physical-hardware evidence. Permanent6vCPU/6GiB unchanged;
VM shut off after delivery, on-demand proxy stopped, other VMs preserved.

**The mem report itself is FAIL**, solely `check_dimm_serial`: QEMU supplies
no valid DIMM serial and the existing strict policy rejects that. `stress_mem`
is PASS for256MiB of1966MiB (13%),150seconds; HTML/PDF/CSV are present. The22
passing workflow assertions do not mean a healthy physical DIMM was accepted.
Physical server/GPU/RAID validation remains NOT_RUN. Evidence/manifest and
retained failures are in `out/release-1.10.7/`.

Pushed source `c4f3b8b`, [run38373267857](https://github.com/yiyezq162/KLBurn/actions/runs/38373267857),
completed on `nas-ci-klburn`:2044passed/0failed; evidence artifact finalized.
These Runner counts are separate from the Build-VM2052 denominator.

Public [v1.10.7 prerelease](https://github.com/yiyezq162/KLBurn/releases/tag/v1.10.7)
contains both ISOs, both SHA256 files and manifest.json. All5server asset digests
match the local files; publication metadata is retained in the evidence folder.

## Previous ISO delivery evidence (2026-10-07)

Version1.10.6, clean source/tag `a8ffc13`: full and mem artifacts copied to
`/Users/li/Projects/KLBurn/out/` and both SHA256 values verified after transfer.
Source2043/root-disk11/mutation135 passed; full firmware51/smoke10/disk-stress32,
mem firmware54/smoke22 passed. Exact artifact names, hashes and resource limits
are in `out/release-1.10.6/manifest.json`; CHANGELOG records the same source.
This is software/ISO acceptance, not fresh physical hardware acceptance.

Manual prerelease publication completed:
[v1.10.6](https://github.com/yiyezq162/KLBurn/releases/tag/v1.10.6), both ISO
assets and their SHA256 files plus the manifest uploaded. Server asset digests
match the locally verified images. Main-source CI at `0523969`,
[run37658758865](https://github.com/yiyezq162/KLBurn/actions/runs/37658758865),
completed on `nas-ci-klburn`:2035passed/0failed, finalized evidence uploaded.
The VM's private sample set yields2043source assertions; retain each actual
denominator. CI still does not automatically build or publish ISO artifacts.

The6GiB VM crashed while starting a build after mutation passed; cause UNKNOWN.
Recovery used a temporary3GiB live balloon,3GiB guest swap and sequential stage
cgroups (build1.8GiB maximum; QEMU2.4GiB maximum plus swap), preserving4GiB of
memory visible inside QEMU. Logs retain earlier OOM/time-window failures.
Persistent6vCPU/6GiB configuration and other VMs were unchanged.
No installed RAM upgrade is assumed. The VM is shut down after delivery.

## Earlier source Runner onboarding evidence

Verified source `95533ae`, [run37565544801](https://github.com/yiyezq162/KLBurn/actions/runs/37565544801):
actual `nas-ci-klburn`, **2029 passed / 0 failed**, finalized source log present.
Hardware replay893passed and report checks363passed; both Mac originals and
all223NAS private input files remained hash-identical and job copies were cleaned.
This includes45sensor samples, not45distinct physical machines or fresh hardware
acceptance. ISO/root/firmware/QEMU gates were NOT_RUN during this onboarding;
current ISO evidence is recorded above.

## Retained migration failures

Source SHA `a2381c6`, [run37565057243](https://github.com/yiyezq162/KLBurn/actions/runs/37565057243):
actual `nas-ci-klburn`, **1937 passed / 2 failed**, finalized log artifact present.
Both failures are mandatory real-hardware coverage checks requiring private,
untracked `test_out` samples (including an observed non-AC power case).
Windows migration had also lost executable modes on both report Python CLIs;
mode-only repair restored report checks to363passed/0failed. Existing real-PDF
conversion cases remain skipped without their optional tooling. Do not invent
samples, upload customer originals or weaken the hardware gate to make CI green.
This source result is not ISO, QEMU, firmware or hardware acceptance.

The owner subsequently restored originals from Mac Downloads to local ignored
`test_out/` (45 sensor-file samples; not45independent machines). NAS keeps only
223 required sensor/power text files under private0700 home path
`/home/runner/.private-fixtures/klburn-hardware-v1`, with anonymous sample numbers
and byte-identical contents; no full HTML/PDF/customer reports were transferred.
Trusted NAS source checks create an owned0700 workspace copy, then remove only
that exact run/attempt-marked copy through an EXIT trap. An initial symlink
intake did not satisfy the tests' find traversal and retained801PASS/2FAIL;
the ordinary-copy correction changes no assertion. Tests copy required input into temporary directories before
writing; originals are not test output. Only aggregate source-check logs are
uploaded, not private fixtures. Cloud PR/fallback has no private dataset and
does not establish the mandatory real-sample coverage gate without an approved
private-input workflow. Do not bypass the assertions to hide that boundary.

| Component | Current role |
| --- | --- |
| `nas-ci-klburn` | Repository-specific nonprivileged Docker Actions Runner; selector `self-hosted, Linux, X64, nas-klburn`; source regression only |
| `KLBurn-BuildVM` | Dedicated Ubuntu24.04 x86 ISO backend; configured6vCPU/6GiB/64GiB sparse disk, stopped/on-demand, autostart off |

Neither is shared with other projects. Runner runtime
`/volume1/services/ci-klburn/compose.yaml`; independent volume
`nas-ci-klburn-home`, workspace `/home/runner/_work`. Registration persists;
ordinary development does not initialize another Runner.

## GitHub workflow and release boundary

`.github/workflows/check.yml` runs non-root source regression with actual
shellcheck after main push, PR or manual dispatch. Trusted push/manual uses NAS;
PRs use disposable Ubuntu24.04 cloud runners. `CI_RUNNER=github` enables cloud
fallback. Unique run/attempt artifacts preserve source-check logs.
iproute2 is required by source fixtures and installed with shellcheck if missing.
Initial NAS upload FinalizeArtifact reset its connection; one bounded retry
uses direct HTTPS only inside that upload action, preserving Runner/job proxy
and TLS/credentials. At least one finalized evidence artifact is mandatory;
failed source tests still fail CI even if upload retries succeed.

**It does not build or release an ISO.** Non-root `run-all.sh` skips root
disk-exclusion. Full/mem ISO builds, firmware audit, real ISO QEMU smoke/full/
disk-stress and physical hardware checks remain required separate gates.
The summary records them as NOT_RUN; never interpret source green as release
acceptance, silently accept missing vendor or publish old/dirty artifacts.

```sh
gh api repos/yiyezq162/KLBurn/actions/runners \
  --jq '.runners[] | {name,status,busy,labels:[.labels[].name]}'
gh run list --repo yiyezq162/KLBurn --workflow check.yml --limit 5
```

## Dedicated build backend facts

Native domain `f041a928-d7ee-4dd3-a031-d2b05f57ecef`, title `KLBurn-BuildVM`,
private guest172.30.91.2. Earlier2GiB bootstrap verified root/chroot/mount/loop/
exFAT/nested KVM and Mihomo → BitsFlow DE/GitHub. The6GiB configuration has since
booted and built both1.10.6 candidate editions; complete release acceptance is
recorded separately in `out/release-1.10.6/`. NAS usable physical RAM7.53GiB:
do not start heavy VM builds beside full CI/lab jobs or assume configured RAM
is physical capacity. Runner source-check ceiling is2CPU/1GiB+1GiB swap.

Guest source `/srv/klburn/src`, explicit `KLBURN_WORK=/srv/klburn/work`,
task-specific `/srv/klburn/e2e` directories, `/srv/klburn/artifacts`.
Only this guest receives privileged mount/loop/KVM work; the Docker Runner has
no KVM, physical disk or NAS Docker socket. **Automatic Runner-to-VM transport
and GitHub Release workflow remain NOT_CONFIGURED**. Manual source/vendor
migration is available through trusted NAS root/QGA and a temporary private
bridge-only transfer server; source checks and `build/release.sh` execute in
the guest. Verified artifacts are copied to the Mac project `out/` and their
SHA256 values checked again. No NAS root key/generic host-exec API is put in CI.

Current guest management is trusted NAS root → QEMU Guest Agent; independent
guest SSH/key/interactive login is not enrolled. Use pinned NAS alias
`nas-dxp4800-plus` and explicit root only for authorized VM/build maintenance.
UGOS mislabels private network/NoCloud seed as missing: do not save those
defaults. VPSManage/vault `20-服务/nas-klburn-buildvm.md` and `nas-ci-runners.md`
own lifecycle/recovery. No global prune or other-project/VM modification.

Before real ISO delivery restore approved offline components/private samples,
confirm a clean commit and follow `docs/building.md` release order. Do not
commit customer originals/licensed binaries. CI/docs-only changes need no ISO
version bump or release tag.
