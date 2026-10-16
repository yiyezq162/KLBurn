#!/usr/bin/env python3
"""KLBurn 定制构建入口；Python 3.10+，仅使用标准库。"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import uuid


def run(args, cwd=None, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def output(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def load_brand_module(source):
    spec = importlib.util.spec_from_file_location("branding", source / "build/branding.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def copy_inputs(source, destination):
    """Explicit offline inputs only. Never copy source out/ or arbitrary symlinks."""
    source = source.resolve(strict=True)
    if not source.is_dir():
        raise ValueError("输入必须是目录")
    for item in source.rglob("*"):
        if item.is_symlink() or not (item.is_file() or item.is_dir()):
            raise ValueError("离线输入中不接受链接或特殊文件")
    shutil.copytree(source, destination, dirs_exist_ok=True)


def configure_custom_identity(source):
    # The release tag is created under sudo, where the caller's global Git
    # identity may not exist. Keep this identity in the generated repo only.
    run(["git", "config", "--local", "user.name", "KLBurn Custom Builder"], source)
    run(["git", "config", "--local", "user.email", "builder@example.invalid"], source)
    run(["git", "config", "--local", "tag.gpgSign", "false"], source)


def prepare(args):
    workspace = args.workspace.expanduser().resolve()
    if workspace.exists():
        raise ValueError("工作区已存在，请选择全新目录；不会覆盖原始源码或已有产物")
    if args.source.startswith("-") or re.search(r"https?://[^/]*@", args.source):
        raise ValueError("源码地址不能含凭据或命令选项")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,150}", args.ref) or ".." in args.ref:
        raise ValueError("源码引用必须是明确的 tag、分支或 commit")
    workspace.mkdir(parents=True)
    source = workspace / "source"
    run(["git", "-c", "protocol.ext.allow=never", "clone", "--no-hardlinks", "--", args.source, str(source)])
    commit = output(["git", "rev-parse", "--verify", args.ref + "^{commit}"], source)
    run(["git", "checkout", "--detach", commit], source)
    # Never retain an upstream push destination in a customized workspace.
    run(["git", "remote", "remove", "origin"], source)
    module = load_brand_module(source)
    brand_path = source / "build/branding.json"
    data = module.load_brand(brand_path)
    data.update(display_name=args.name, console_name=args.console_name, custom=True)
    if args.report_title:
        data["report_title"] = args.report_title
    if args.mem_report_title:
        data["mem_report_title"] = args.mem_report_title
    if args.logo:
        image = args.logo.read_bytes()
        if len(image) > 1024 * 1024 or not image.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("logo 必须是 1 MiB 以内的 PNG 图片")
        # Tracked custom branding is preserved in this private workspace only.
        (source / "build/custom-logo.png").write_bytes(image)
        data["logo"] = "custom-logo.png"
        data["logo_sha256"] = hashlib.sha256(image).hexdigest()
    else:
        data["logo"] = ""
        data["logo_sha256"] = ""
    brand_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    module.load_brand(brand_path)
    digest = module.constants(data, "full")["BRAND_SHA256"]
    config = source / "build/config.sh"
    content = config.read_text(encoding="utf-8")
    match = re.search(r'^KLBURN_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$', content, re.M)
    if not match:
        raise ValueError("源码版本格式不受支持；请使用官方源码版本")
    version = match[1] + "-custom." + digest[:12]
    content = content[:match.start()] + 'KLBURN_VERSION="' + version + '"' + content[match.end():]
    config.write_text(content, encoding="utf-8", newline="\n")
    provenance = {"upstream_commit": commit, "version": version, "branding_sha256": digest,
                  "official": False, "publication": "disabled"}
    (source / "build/custom-build.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8", newline="\n")
    configure_custom_identity(source)
    run(["git", "add", "build"], source)
    run(["git", "-c", "user.name=KLBurn Custom Builder", "-c", "user.email=builder@example.invalid",
         "-c", "commit.gpgsign=false", "commit", "-m", "build: private custom branding " + digest[:12]], source)
    if args.vendor:
        copy_inputs(args.vendor, source / "vendor")
    if args.fixtures:
        copy_inputs(args.fixtures, source / "test_out")
    if output(["git", "status", "--porcelain"], source):
        raise ValueError("工作区出现未提交修改；停止构建，保留现场")
    print("已生成独立定制工作区：", workspace)
    print("定制版本：", version, "；不会推送或上传任何品牌资料")
    return workspace, source


def preflight():
    if sys.platform != "linux" or platform.machine() not in ("x86_64", "amd64"):
        raise ValueError("后端需要 x86_64 Ubuntu 24.04；Apple Silicon/macOS 请使用 SSH 后端")
    release = dict(line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release.get("ID", "").strip('"') != "ubuntu" or release.get("VERSION_ID", "").strip('"') != "24.04":
        raise ValueError("后端必须为 Ubuntu 24.04；请使用符合条件的本机、WSL 或 SSH 构建机")
    required = ("bash", "git", "sudo", "python3", "shellcheck", "xorriso", "mksquashfs", "unsquashfs",
                "rsync", "curl", "jq", "qemu-system-x86_64", "losetup", "mkfs.exfat", "readelf", "modinfo", "findmnt")
    missing = [name for name in required if not shutil.which(name)]
    if missing:
        raise ValueError("缺少后端工具：" + ", ".join(missing) + "。请按 docs/building.md 安装后重试；本工具不会自动安装")
    if not Path("/dev/kvm").exists():
        raise ValueError("缺少 /dev/kvm；请由管理员启用硬件/嵌套虚拟化，不以软件模拟冒充 KVM 验收")
    filesystem = output(["findmnt", "-n", "-o", "FSTYPE", "-T", str(Path.cwd())])
    if filesystem not in {"ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs"}:
        raise ValueError("构建工作区需要受支持的 Linux 本地文件系统；当前为 " + filesystem
                         + "。不要使用 SMB/NFS/9p、临时内存盘或普通容器工作区")
    if shutil.disk_usage(Path.cwd()).free < 40 * 1024**3:
        raise ValueError("工作区所在磁盘至少需要 40 GiB 可用空间，请选择 Linux 本地文件系统或归档旧产物")
    run(["sudo", "-n", "test", "-r", "/dev/kvm"])
    run(["sudo", "-n", "test", "-w", "/dev/kvm"])
    print("后端基本预检通过；离线依赖、源码回归、loop/mount 和 ISO 验收仍由发布入口逐项检查")


def build_local(source, workspace):
    os.chdir(workspace)
    preflight()
    configure_custom_identity(source)
    if not (source / "vendor/full-vendor.sha256").is_file():
        raise ValueError("缺少经过核对的离线组件清单 vendor/full-vendor.sha256；不生成缺件 ISO")
    if not (source / "test_out").is_dir():
        raise ValueError("缺少私有硬件回归输入。现有严格发布门槛需要真实传感器/电源样本；不会删除或绕过此守卫")
    log = workspace / "build.log"
    command = ["sudo", "-n"]
    # Respect the user's existing network configuration without putting proxy
    # credentials into argv/logs or preserving unrelated environment variables.
    proxy_keys = ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
                  "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY")
    configured = [key for key in proxy_keys if os.environ.get(key)]
    if configured:
        command.append("--preserve-env=" + ",".join(configured))
    command += ["env", "KLBURN_WORK=" + str(workspace / "work"),
                "bash", "./build/release.sh", "--mutate"]
    with log.open("ab") as stream:
        result = subprocess.run(command, cwd=source, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError("构建/验收未通过，日志保留在 " + str(log))
    print("双版产物、SHA256 与验收记录：", source / "out")
    print("真机硬件验收 NOT_RUN；Windows/macOS 入口运行不代表本机能构建 ISO")


def verify_collected(output_dir, version, commit):
    """An empty checksum glob is not a successful paired release."""
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-custom\.[a-f0-9]{12}", version):
        raise ValueError("定制版本格式无效")
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("定制源码 commit 无效")
    output_dir = Path(output_dir)
    receipt_path = output_dir / ("release-" + version) / "manifest.json"
    if (receipt_path.is_symlink() or not receipt_path.is_file()
            or not receipt_path.resolve().is_relative_to(output_dir.resolve())):
        raise ValueError("缺少本版本完整的双版验收收据")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if not isinstance(receipt, dict) or receipt.get("version") != version or receipt.get("commit") != commit:
        raise ValueError("下载的收据与本次定制版本/源码 commit 不一致")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != {"full", "mem"}:
        raise ValueError("验收收据必须同时包含 full 和 mem")
    for edition in ("full", "mem"):
        item = artifacts[edition]
        prefix = "KLBurn-MEM-" if edition == "mem" else "KLBurn-"
        if (not isinstance(item, dict) or not isinstance(item.get("file"), str)
                or not re.fullmatch(re.escape(prefix + version) + r"-[0-9]{8}\.iso", item["file"])
                or type(item.get("bytes")) is not int or item["bytes"] <= 0
                or not isinstance(item.get("sha256"), str)
                or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"])):
            raise ValueError("双版资产收据中的文件名、大小或哈希无效")
        iso = output_dir / item["file"]
        checksum = output_dir / (item["file"] + ".sha256")
        if iso.is_symlink() or checksum.is_symlink() or not iso.is_file() or not checksum.is_file():
            raise ValueError("双版 ISO 或 SHA256 文件缺失/为链接")
        if iso.stat().st_size != item["bytes"] or checksum.read_text(encoding="ascii").strip() != item["sha256"]:
            raise ValueError("下载的大小或 SHA256 文件与收据不一致")
        digest = hashlib.sha256()
        with iso.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != item["sha256"]:
            raise ValueError("下载后 ISO 哈希不一致；禁止交付")
    return receipt


def build_ssh(args, source, workspace):
    if not args.ssh or not re.fullmatch(r"(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9_.-]*", args.ssh):
        raise ValueError("SSH 目标须为已配置的主机别名或 user@hostname；端口/密钥请配置在 ~/.ssh/config")
    remote = "/var/tmp/klburn-custom-" + uuid.uuid4().hex
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", args.ssh]
    # No credentials, key enrollment, network changes or VM provisioning.
    archive = workspace / "source.tar"
    # NTFS and permissive Git settings can lose executable bits while still
    # reporting a clean checkout. Transfer committed modes, not sender OS modes.
    tracked_modes = {}
    for record in subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=source).split(b"\0"):
        if not record:
            continue
        header, name = record.split(b"\t", 1)
        mode, _, stage = header.split()
        if stage != b"0" or mode not in (b"100644", b"100755"):
            raise ValueError("SSH 构建仅接受已提交的普通源码文件，不接受冲突、链接或子模块")
        tracked_modes["source/" + name.decode("utf-8")] = int(mode, 8) & 0o777

    def committed_permissions(member):
        if member.name in tracked_modes:
            if not member.isfile():
                raise ValueError("源码文件类型与 Git 记录不一致")
            member.mode = tracked_modes[member.name]
        return member

    with tarfile.open(archive, "w") as tar:
        tar.add(source, arcname="source", recursive=True, filter=committed_permissions)
    run(ssh + ["mkdir -m 700 -- " + remote])
    with archive.open("rb") as stream:
        # Root on the backend must not recreate the Mac/Windows user's numeric UID.
        # Keep Git ownership checks enabled; the receiving user owns this workspace.
        run(ssh + ["tar --no-same-owner -xf - -C " + remote], stdin=stream)
    receipt = {"remote_workspace": remote, "ssh_target": args.ssh, "session_log": "ssh-session.log",
               "cleanup": "manual after verified collection"}
    (workspace / "remote-build.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    remote_command = ("git -C " + remote + "/source config --local core.filemode true && python3 "
                      + remote + "/source/tools/customize/klburn-builder.py --resume " + remote)
    session_log = workspace / "ssh-session.log"
    print("SSH 会话日志（包括预检失败）：", session_log, flush=True)
    with session_log.open("ab") as stream:
        result = subprocess.run(ssh + [remote_command], stdout=stream, stderr=subprocess.STDOUT)
    # Keep both success and failure logs. No delete or automatic publication.
    with session_log.open("ab") as stream:
        log_copy = subprocess.run(["scp", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                                   args.ssh + ":" + remote + "/build.log", str(workspace / "build.log")],
                                  stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError("SSH 构建未通过；会话日志保留：" + str(session_log) + "；远端工作区：" + remote)
    if log_copy.returncode:
        raise ValueError("构建日志未收集成功；请保留并检查远端工作区：" + remote)
    run(["scp", "-r", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
         args.ssh + ":" + remote + "/source/out", str(workspace / "output")])
    provenance = json.loads((source / "build/custom-build.json").read_text(encoding="utf-8"))
    verify_collected(workspace / "output", provenance["version"], output(["git", "rev-parse", "HEAD"], source))
    print("远端双版构建与验收通过，下载后 SHA256 已复核：", workspace / "output")


def main():
    if sys.version_info < (3, 10):
        raise SystemExit("需要 Python 3.10 或更新版本；请安装后重新运行。")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="https://github.com/yiyezq162/KLBurn.git")
    parser.add_argument("--ref", help="明确的官方 tag/commit；不会默认为未知的最新版")
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--name", default="KLBurn")
    parser.add_argument("--console-name", default="KLBurn Custom")
    parser.add_argument("--report-title")
    parser.add_argument("--mem-report-title")
    parser.add_argument("--logo", type=Path)
    parser.add_argument("--vendor", type=Path)
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--backend", choices=("prepare", "local", "ssh"), default="prepare")
    parser.add_argument("--ssh", help="预先配置好 host key、密钥与免交互 sudo 的 SSH 主机")
    parser.add_argument("--resume", type=Path, help="继续已准备好的定制工作区（Linux 后端）")
    parser.add_argument("--check-backend", action="store_true")
    parser.add_argument("--dependencies", action="store_true", help="显示第三方组件官方获取链接和许可边界")
    args = parser.parse_args()
    try:
        if args.dependencies:
            catalog = json.loads(Path(__file__).with_name("dependencies.json").read_text(encoding="utf-8"))
            print(catalog["policy"])
            for item in catalog["components"]:
                print("\n" + item["name"] + "\n" + item["url"] + "\n放置：" + item["destination"] + "\n许可：" + item["redistribution"])
            return
        if args.check_backend:
            preflight()
            return
        if args.resume:
            workspace = args.resume.resolve(strict=True)
            source = workspace / "source"
            if not (source / "build/custom-build.json").is_file():
                raise ValueError("该目录不是本工具建立的定制工作区")
            if output(["git", "status", "--porcelain"], source):
                raise ValueError("源码已变化；请检查并提交后再继续")
            build_local(source, workspace)
            return
        if not args.ref:
            args.ref = input("源码 tag 或 commit：").strip()
        if not args.workspace:
            args.workspace = Path(input("全新独立工作区路径：").strip())
        workspace, source = prepare(args)
        if args.backend == "local":
            build_local(source, workspace)
        elif args.backend == "ssh":
            build_ssh(args, source, workspace)
        else:
            print("仅准备完成，构建与验收 NOT_RUN。选择 Linux 本机后端后才执行构建。")
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, "停止：" + str(exc) + "\n原始源码不变；保留定制工作区用于检查和恢复。\n")


if __name__ == "__main__":
    main()
