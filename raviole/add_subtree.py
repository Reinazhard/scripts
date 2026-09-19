"""
Import Android kernel modules and devices.

This script imports Google-specific kernel modules and device trees from AOSP
repositories using git subtree, or copies them from local directories.

Usage:
    # Import from AOSP using git subtree
    python add_subtree.py android-gs-raviole-6.1-android16

    # Import specific modules
    python add_subtree.py main --modules amplifiers,gpu

    # Import from local directory
    python add_subtree.py --import-method copy --source-dir /path/to/extracted/private

    # Dry run (preview without executing)
    python add_subtree.py android-gs-raviole-6.1-android16 --dry-run

    # Parallel import with 4 workers
    python add_subtree.py main -j 4

See LICENSE file for copyright and license details.
"""

from __future__ import annotations

import argparse
import subprocess
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, Tuple
from urllib.parse import urljoin

# Module definitions with their respective repositories
MODULES = {
    "amplifiers": "kernel/google-modules/amplifiers",
    "aoc": "kernel/google-modules/aoc",
    "aoc_ipc": "kernel/google-modules/aoc-ipc",
    "bms": "kernel/google-modules/bms",
    "bluetooth/broadcom": "kernel/google-modules/bluetooth/broadcom",
    "display/common": "kernel/google-modules/display/common",
    "display/samsung": "kernel/google-modules/display/samsung",
    "edgetpu/abrolhos": "kernel/google-modules/edgetpu/abrolhos",
    "fingerprint/goodix": "kernel/google-modules/fingerprint/goodix",
    "gps/broadcom/bcm47765": "kernel/google-modules/gps/broadcom/bcm47765",
    "gpu": "kernel/google-modules/gpu",
    "lwis": "kernel/google-modules/lwis",
    "nfc": "kernel/google-modules/nfc",
    "power/mitigation": "kernel/google-modules/power/mitigation",
    "power/reset": "kernel/google-modules/power/reset",
    "soc/gs": "kernel/google-modules/soc/gs",
    "radio/samsung/s5300": "kernel/google-modules/radio/samsung/s5300",
    "touch/common": "kernel/google-modules/touch/common",
    "touch/fts": "kernel/google-modules/touch/fts_touch",
    "touch/sec": "kernel/google-modules/touch/sec_touch",
    "trusty": "kernel/google-modules/trusty",
    "uwb/qorvo/dw3000": "kernel/google-modules/uwb/qorvo/dw3000",
    "video/gchips": "kernel/google-modules/video/gchips",
    "wlan/bcm4389": "kernel/google-modules/wlan/bcmdhd/bcm4389",
}

# Device definitions with their respective repositories
DEVICES = {
    "gs101": "kernel/devices/google/gs101",
    "raviole": "kernel/devices/google/raviole",
    "bluejay": "kernel/devices/google/bluejay",
}

# Repository base URL
REPO_BASE = "https://android.googlesource.com/"


def is_git_repo() -> bool:
    """Check if the current directory is inside a git repository."""
    try:
        subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            check=True,
            capture_output=True,
        )
        return True
    except subprocess.CalledProcessError:
        return False


def check_ref_exists(repo_url: str, ref: str, timeout: int = 30) -> Tuple[bool, Optional[str]]:
    """Check if a branch, tag, or commit exists in the remote repository."""
    try:
        result = subprocess.run(
            ["git", "ls-remote", repo_url, ref],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if not result.stdout.strip():
            return False, None

        for line in result.stdout.strip().splitlines():
            line = line.strip()
            if not line:
                continue
            ref_path = line.split()[-1] if len(line.split()) >= 2 else ""
            if ref_path.startswith("refs/heads/"):
                return True, "branch"
            if ref_path.startswith("refs/tags/"):
                return True, "tag"

        return True, "commit"
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False, None


def import_via_subtree(module_name: str, local_path: str, repo_url: str, ref: str, timeout: int = 300) -> bool:
    """Import module using git subtree from remote repository."""
    print(
        f"Adding subtree for {module_name} into {local_path} from {repo_url} (ref: {ref})..."
    )

    if os.path.isdir(local_path):
        print(f"Directory {local_path} already exists. Skipping subtree addition.")
        return False

    try:
        subprocess.run(
            [
                "git",
                "subtree",
                "add",
                "--prefix",
                local_path,
                "--squash",
                repo_url,
                ref,
            ],
            check=True,
            timeout=timeout,
        )
        print(f"Successfully added subtree for {module_name}")
        return True
    except subprocess.CalledProcessError as e:
        print(
            f"Error: Failed to add subtree for {module_name} from {repo_url}. Error: {e}"
        )
        return False
    except subprocess.TimeoutExpired:
        print(
            f"Error: Subtree add for {module_name} timed out after {timeout}s."
        )
        return False


def fix_broken_symlinks(directory: str) -> tuple[int, int]:
    """Fix broken symlinks in a directory tree.

    For each broken symlink, attempts to resolve the target relative to the
    symlink's parent directory within the same tree.

    Returns:
        Tuple of (fixed_count, unfixed_count).
    """
    fixed = 0
    unfixed = 0
    for dirpath, _, filenames in os.walk(directory, followlinks=False):
        for fname in filenames:
            full_path = os.path.join(dirpath, fname)
            if not os.path.islink(full_path):
                continue
            target = os.readlink(full_path)
            if os.path.exists(full_path):
                continue
            resolved = os.path.normpath(os.path.join(dirpath, target))
            if os.path.exists(resolved):
                os.remove(full_path)
                os.symlink(resolved, full_path)
                fixed += 1
            else:
                unfixed += 1
    return fixed, unfixed


def import_via_copy(module_name: str, source_path: str, dest_path: str, force: bool = False) -> bool:
    """Import module by copying from local source directory."""
    import shutil

    if not os.path.isdir(source_path):
        print(f"Warning: Source directory {source_path} not found. Skipping {module_name}.")
        return False

    if os.path.exists(dest_path):
        if not force:
            print(f"Warning: Destination {dest_path} already exists. Skipping (use --force to overwrite).")
            return False
        else:
            print(f"Removing existing {dest_path}...")
            shutil.rmtree(dest_path)

    try:
        print(f"Copying {module_name} from {source_path} to {dest_path}...")
        shutil.copytree(source_path, dest_path, symlinks=True)
        fixed, unfixed = fix_broken_symlinks(dest_path)
        if fixed:
            print(f"Fixed {fixed} broken symlink(s) in {module_name}")
        if unfixed:
            print(f"Warning: {unfixed} broken symlink(s) in {module_name} could not be resolved")
        print(f"Successfully copied {module_name}")
        return True
    except Exception as e:
        print(f"Error: Failed to copy {module_name}. Error: {e}")
        return False


def process_single_item(
    item_key: str,
    repo_name: str,
    item_type: str,
    import_method: str,
    ref: Optional[str],
    source_dir: Optional[str],
    force: bool,
    dry_run: bool,
    progress: Optional[str] = None,
) -> bool:
    """Process a single module or device item. Returns True on success."""
    dest_prefix = "google-modules" if item_type == "module" else "google-devices"
    dest_path = f"{dest_prefix}/{item_key}"

    if progress:
        print(f"[{progress}] Processing {item_key}...")

    if import_method == "subtree":
        repo_url = urljoin(REPO_BASE, repo_name)
        exists, ref_type = check_ref_exists(repo_url, ref)
        if not exists:
            print(f"Warning: Ref '{ref}' not found in {repo_name}. Skipping.")
            return False
        if ref_type:
            print(f"Found '{ref}' as {ref_type} in {repo_name}")
        
        if dry_run:
            print(f"[dry-run] Would add subtree for {item_key} into {dest_path}")
            return True
        return import_via_subtree(item_key, dest_path, repo_url, ref)
    else:
        # Copy mode
        source_path = os.path.join(source_dir, dest_prefix, item_key)
        if item_type == "device":
            if not os.path.isdir(source_path):
                source_path = os.path.join(source_dir, "devices", "google", item_key)
        
        if dry_run:
            print(f"[dry-run] Would copy {item_key} from {source_path} to {dest_path}")
            return True
        return import_via_copy(item_key, source_path, dest_path, force)


def process_modules_and_devices(
    ref: Optional[str] = None,
    modules_filter: Optional[list[str]] = None,
    devices_filter: Optional[list[str]] = None,
    modules_only: bool = False,
    devices_only: bool = False,
    import_method: str = "subtree",
    source_dir: Optional[str] = None,
    force: bool = False,
    dry_run: bool = False,
    jobs: int = 1,
) -> None:
    """Process and import modules and devices using specified method."""

    # Validate import method
    if import_method == "subtree":
        if not is_git_repo():
            sys.exit("Error: Subtree mode requires a git repository.")
        if not ref:
            sys.exit("Error: Subtree mode requires a ref argument.")
    elif import_method == "copy":
        if not source_dir:
            sys.exit("Error: Copy mode requires --source-dir.")
        if not os.path.isdir(source_dir):
            sys.exit(f"Error: Source directory {source_dir} does not exist.")
    else:
        sys.exit(f"Error: Invalid import method: {import_method}")

    # Build work items list
    work_items = []
    if not devices_only:
        modules_to_process = MODULES
        if modules_filter:
            modules_to_process = {k: v for k, v in MODULES.items() if k in modules_filter}
            if not modules_to_process:
                print(f"Warning: None of the specified modules found. Available modules: {', '.join(MODULES.keys())}")
        for module_key, repo_name in modules_to_process.items():
            work_items.append((module_key, repo_name, "module"))

    if not modules_only:
        devices_to_process = DEVICES
        if devices_filter:
            devices_to_process = {k: v for k, v in DEVICES.items() if k in devices_filter}
            if not devices_to_process:
                print(f"Warning: None of the specified devices found. Available devices: {', '.join(DEVICES.keys())}")
        for device_key, repo_name in devices_to_process.items():
            work_items.append((device_key, repo_name, "device"))

    if not work_items:
        print("No modules or devices to process.")
        return

    total_count = len(work_items)
    item_type = "modules" if not devices_only else "devices"
    if import_method == "subtree":
        print(f"Processing {total_count} {item_type} from AOSP repository using ref '{ref}'...")
    else:
        print(f"Processing {total_count} {item_type} from {source_dir}...")

    success_count = 0
    if jobs > 1:
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = {
                executor.submit(
                    process_single_item, key, repo, typ, import_method, ref, source_dir, force, dry_run
                ): key
                for key, repo, typ in work_items
            }
            for i, future in enumerate(as_completed(futures), 1):
                if future.result():
                    success_count += 1
    else:
        for i, (key, repo, typ) in enumerate(work_items, 1):
            if process_single_item(key, repo, typ, import_method, ref, source_dir, force, dry_run, f"{i}/{total_count}"):
                success_count += 1

    print(f"\nCompleted: {success_count}/{total_count} items processed successfully.")
    if success_count < total_count:
        print("Some items were skipped due to errors or missing refs.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Import Android kernel modules and devices using git subtree or local copy.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples (git subtree mode - default):
  %(prog)s android-gs-raviole-6.1-android16
  %(prog)s main --modules amplifiers,gpu
  %(prog)s android-16.0.0_r1 -m "display/samsung,touch/common"
  %(prog)s android-16-beta-4.1_r0.1 --devices gs101,raviole

Examples (copy mode - from extracted tarball):
  %(prog)s --import-method copy --source-dir /path/to/extracted/private
  %(prog)s --import-method copy --source-dir ./private --modules gpu,amplifiers
  %(prog)s --import-method copy --source-dir ./vendor-tree --devices gs101 --force

Examples (dry-run and parallel):
  %(prog)s android-gs-raviole-6.1-android16 --dry-run
  %(prog)s main -j 4 --modules amplifiers,gpu,nfc
  %(prog)s android-16.0.0_r1 --log-file import.log
        """,
    )

    parser.add_argument(
        "ref",
        nargs="?",
        help="Branch, tag, or commit reference (required for subtree mode)"
    )

    parser.add_argument(
        "--import-method",
        choices=["subtree", "copy"],
        default="subtree",
        help="Import method: 'subtree' for git subtree (default), 'copy' for local copy"
    )

    parser.add_argument(
        "--source-dir",
        help="Source directory for copy mode (required when --import-method copy)"
    )

    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing destinations in copy mode"
    )

    parser.add_argument(
        "-m", "--modules", help="Comma-separated list of specific modules to fetch"
    )

    parser.add_argument(
        "-d", "--devices", help="Comma-separated list of specific devices to fetch"
    )

    parser.add_argument(
        "--modules-only", action="store_true", help="Fetch only modules, skip devices"
    )

    parser.add_argument(
        "--devices-only", action="store_true", help="Fetch only devices, skip modules"
    )

    parser.add_argument(
        "--list-modules",
        action="store_true",
        help="List all available modules and exit",
    )

    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List all available devices and exit",
    )

    parser.add_argument(
        "--list-all",
        action="store_true",
        help="List all available modules and devices and exit",
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview actions without executing",
    )

    parser.add_argument(
        "-j", "--jobs",
        type=int,
        default=1,
        help="Number of parallel import jobs (default: 1)",
    )

    parser.add_argument(
        "--log-file",
        help="Write output to log file",
    )

    args = parser.parse_args()

    # Set up file logging if specified
    log_file = None
    if args.log_file:
        try:
            log_file = open(args.log_file, "w")
            sys.stdout = log_file
            sys.stderr = log_file
        except OSError as e:
            sys.exit(f"Error: Cannot open log file {args.log_file}: {e}")

    try:
        # Handle listing options
        if args.list_modules or args.list_all:
            print("Available modules:")
            for module in sorted(MODULES.keys()):
                print(f"  {module}")
            if not args.list_all:
                sys.exit(0)

        if args.list_devices or args.list_all:
            if args.list_all:
                print("\nAvailable devices:")
            else:
                print("Available devices:")
            for device in sorted(DEVICES.keys()):
                print(f"  {device}")
            sys.exit(0)

        # Validate arguments based on import method
        if args.import_method == "subtree" and not args.ref:
            parser.error("ref argument is required for subtree mode")
        
        if args.import_method == "copy" and not args.source_dir:
            parser.error("--source-dir is required for copy mode")

        # Validate conflicting options
        if args.modules_only and args.devices_only:
            sys.exit("Error: Cannot specify both --modules-only and --devices-only")

        # Parse modules filter
        modules_filter = None
        if args.modules:
            modules_filter = [m.strip() for m in args.modules.split(",")]
            invalid_modules = [m for m in modules_filter if m not in MODULES]
            if invalid_modules:
                print(f"Warning: Invalid modules specified: {', '.join(invalid_modules)}")
                print(f"Valid modules: {', '.join(sorted(MODULES.keys()))}")
                modules_filter = [m for m in modules_filter if m in MODULES]
                if not modules_filter:
                    sys.exit("Error: No valid modules specified.")

        # Parse devices filter
        devices_filter = None
        if args.devices:
            devices_filter = [d.strip() for d in args.devices.split(",")]
            invalid_devices = [d for d in devices_filter if d not in DEVICES]
            if invalid_devices:
                print(f"Warning: Invalid devices specified: {', '.join(invalid_devices)}")
                print(f"Valid devices: {', '.join(sorted(DEVICES.keys()))}")
                devices_filter = [d for d in devices_filter if d in DEVICES]
                if not devices_filter:
                    sys.exit("Error: No valid devices specified.")

        process_modules_and_devices(
            ref=args.ref,
            modules_filter=modules_filter,
            devices_filter=devices_filter,
            modules_only=args.modules_only,
            devices_only=args.devices_only,
            import_method=args.import_method,
            source_dir=args.source_dir,
            force=args.force,
            dry_run=args.dry_run,
            jobs=args.jobs,
        )
    finally:
        if log_file:
            log_file.close()
            sys.stdout = sys.__stdout__
            sys.stderr = sys.__stderr__


if __name__ == "__main__":
    main()
