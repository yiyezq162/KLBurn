# KLBurn dedicated NAS Runner and build VM

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
Trusted NAS source checks link this directory for the job then unlink only that
exact reference. Tests copy required input into temporary directories before
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
exFAT/nested KVM and Mihomo → BitsFlow DE/GitHub. The6GiB stopped configuration
has not passed a boot/full working-set check. NAS usable physical RAM7.53GiB:
do not start heavy VM builds beside full CI/lab jobs or assume configured RAM
is physical capacity. Runner source-check ceiling is2CPU/1GiB+1GiB swap.

Guest source `/srv/klburn/src`, explicit `KLBURN_WORK=/srv/klburn/work`,
task-specific `/srv/klburn/e2e` directories, `/srv/klburn/artifacts`.
Only this guest receives privileged mount/loop/KVM work; the Docker Runner has
no KVM, physical disk or NAS Docker socket. **Runner-to-VM build transport,
source/vendor migration and Release workflow are NOT_CONFIGURED** by this
source-Runner onboarding. No NAS root key/generic host-exec API is put in CI.

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
