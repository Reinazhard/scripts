"""
MIT License

Copyright (c) 2025 M. "Harumajati" Alfarozi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

import argparse
import subprocess
import os
import sys
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
    "edgetpu/abrolhos/drivers/edgetpu": "kernel/google-modules/edgetpu/abrolhos",
    "fingerprint/goodix": "kernel/google-modules/fingerprint/goodix",
    "gps/broadcom/bcm47765": "kernel/google-modules/gps/broadcom/bcm47765",
    "gpu": "kernel/google-modules/gpu",
    "lwis": "kernel/google-modules/lwis",
    "nfc": "kernel/google-modules/nfc",
    "power/mitigation": "kernel/google-modules/power/mitigation",
    "power/reset": "kernel/google-modules/power/reset",
    "radio/samsung/s5300": "kernel/google-modules/radio/samsung/s5300",
    "touch/common": "kernel/google-modules/touch/common",
    "touch/fts": "kernel/google-modules/touch/fts_touch",
    "trusty": "kernel/google-modules/trusty",
    "uwb/qorvo/dw3000/kernel": "kernel/google-modules/uwb/qorvo/dw3000",
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


def is_git_repo():
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


def check_branch_exists(repo_url, branch):
    """Check if a branch exists in the remote repository."""
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--heads", repo_url, f"refs/heads/{branch}"],
            check=True,
            capture_output=True,
            text=True,
        )
        return bool(result.stdout.strip())
    except subprocess.CalledProcessError:
        return False


def add_git_subtree(module_name, local_path, repo_url, branch):
    """Add a git subtree for the given module."""
    print(
        f"Adding subtree for {module_name} into {local_path} from {repo_url} (branch: {branch})..."
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
                branch,
            ],
            check=True,
        )
        print(f"Successfully added subtree for {module_name}")
        return True
    except subprocess.CalledProcessError as e:
        print(
            f"Error: Failed to add subtree for {module_name} from {repo_url}. Error: {e}"
        )
        return False


def process_modules_and_devices(
    branch,
    modules_filter=None,
    devices_filter=None,
    modules_only=False,
    devices_only=False,
):
    """Process and add git subtrees for specified modules and devices."""

    if not is_git_repo():
        sys.exit("Error: Not inside a git repository.")

    success_count = 0
    total_count = 0

    # Process modules unless devices_only is specified
    if not devices_only:
        # Filter modules if specified
        modules_to_process = MODULES
        if modules_filter:
            modules_to_process = {
                k: v for k, v in MODULES.items() if k in modules_filter
            }
            if not modules_to_process:
                print(
                    f"Warning: None of the specified modules found. Available modules: {', '.join(MODULES.keys())}"
                )

        if modules_to_process:
            total_count += len(modules_to_process)
            print(
                f"Processing {len(modules_to_process)} modules from AOSP repository using branch '{branch}'..."
            )

            for module_key, repo_name in modules_to_process.items():
                repo_url = urljoin(REPO_BASE, repo_name)
                local_path = f"google-modules/{module_key}"

                # Check if branch exists in the repository
                if not check_branch_exists(repo_url, branch):
                    print(
                        f"Warning: Branch '{branch}' not found in {repo_name}. Skipping."
                    )
                    continue

                if add_git_subtree(module_key, local_path, repo_url, branch):
                    success_count += 1

    # Process devices unless modules_only is specified
    if not modules_only:
        # Filter devices if specified
        devices_to_process = DEVICES
        if devices_filter:
            devices_to_process = {
                k: v for k, v in DEVICES.items() if k in devices_filter
            }
            if not devices_to_process:
                print(
                    f"Warning: None of the specified devices found. Available devices: {', '.join(DEVICES.keys())}"
                )

        if devices_to_process:
            total_count += len(devices_to_process)
            print(
                f"Processing {len(devices_to_process)} devices from AOSP repository using branch '{branch}'..."
            )

            for device_key, repo_name in devices_to_process.items():
                repo_url = urljoin(REPO_BASE, repo_name)
                local_path = f"google-devices/{device_key}"

                # Check if branch exists in the repository
                if not check_branch_exists(repo_url, branch):
                    print(
                        f"Warning: Branch '{branch}' not found in {repo_name}. Skipping."
                    )
                    continue

                if add_git_subtree(device_key, local_path, repo_url, branch):
                    success_count += 1

    if total_count == 0:
        print("No modules or devices to process.")
        return

    print(f"\nCompleted: {success_count}/{total_count} items processed successfully.")

    if success_count < total_count:
        print("Some items were skipped due to errors or missing branches.")


def main():
    parser = argparse.ArgumentParser(
        description="Fetch and add Android kernel modules and devices using git subtree.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s -b android-gs-raviole-6.1-android16
  %(prog)s --branch main --modules amplifiers/cs35l41,gpu/mali_pixel
  %(prog)s -b android-16.0.0_r1 -m "display/samsung,touch/common"
  %(prog)s -b main --devices gs101,raviole
  %(prog)s -b android-gs-raviole-6.1-android16 --modules-only
  %(prog)s -b android-gs-6.1 --devices-only
        """,
    )

    parser.add_argument(
        "-b",
        "--branch",
        required=True,
        help="Branch name to fetch from AOSP repositories",
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

    args = parser.parse_args()

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
        args.branch,
        modules_filter,
        devices_filter,
        args.modules_only,
        args.devices_only,
    )


if __name__ == "__main__":
    main()
