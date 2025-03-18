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
import xml.etree.ElementTree as ET
import subprocess
import os
import sys

# List of desired modules
MODULES = {
    "soc/gs", "amplifiers", "aoc", "aoc_ipc", "bluetooth/broadcom", "bms",
    "display/samsung", "display/common", "edgetpu/abrolhos", "fingerprint/fpc",
    "gps/broadcom/bcm47765", "gpu", "lwis", "power/reset", "power/mitigation",
    "sensors/hall_sensor", "radio/samsung/s5300", "touch/common", "touch/fts",
    "trusty", "uwb/qorvo/dw3000", "video/gchips_whi", "nfc", "wlan/bcm4389"
}

def parse_manifest(manifest_file):
    """Parse the manifest XML file and extract revisions."""
    try:
        tree = ET.parse(manifest_file)
        root = tree.getroot()
        
        # Get default (AOSP) revision
        default_revision = root.find(".//default").get("revision", "")
        if not default_revision:
            raise ValueError("Default AOSP revision not found.")

        # Get Helluva revision (fallback to AOSP if missing)
        helluva_revision = None
        for remote in root.findall(".//remote"):
            if remote.get("name") == "helluva":
                helluva_revision = remote.get("revision", default_revision)
                break  # Stop searching once found

        if not helluva_revision:
            print("Warning: Helluva revision not found. Falling back to AOSP revision.")

        return default_revision, helluva_revision, root.findall(".//project")

    except ET.ParseError as e:
        sys.exit(f"Error: Failed to parse manifest file - {e}")
    except (AttributeError, ValueError) as e:
        sys.exit(f"Error: {e}")

def is_git_repo():
    """Check if the current directory is inside a git repository."""
    try:
        subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], check=True, capture_output=True)
        return True
    except subprocess.CalledProcessError:
        return False

def add_git_subtree(name, path, repo_url, revision):
    """Add a git subtree for the given module."""
    print(f"Adding subtree for {name} into {path} from {repo_url} (revision: {revision})...")

    if not os.path.isdir(path):
        try:
            subprocess.run(["git", "subtree", "add", "--prefix", path, "--squash", repo_url, revision], check=True)
        except subprocess.CalledProcessError:
            print(f"Error: Failed to add subtree for {name} from {repo_url}. Skipping.")
    else:
        print(f"Directory {path} already exists. Skipping subtree addition.")

def process_manifest(manifest_file):
    """Process the manifest and add git subtrees for specified modules."""
    default_revision, helluva_revision, projects = parse_manifest(manifest_file)

    if not is_git_repo():
        sys.exit("Error: Not inside a git repository.")

    for project in projects:
        path = project.get("path")
        name = project.get("name")
        remote = project.get("remote", "aosp")
        revision = project.get("revision", default_revision)

        # Use Helluva revision if available, otherwise fallback to AOSP
        if remote == "helluva":
            revision = helluva_revision or default_revision  # Fallback applied here

        # Check if module is in the list
        module_key = path.replace("private/google-modules/", "")
        if module_key not in MODULES:
            continue

        # Determine repo base URL
        base_url = "https://android.googlesource.com" if remote == "aosp" else "https://gitlab.hentaios.com/hentaios-gs-6.x"
        repo_url = f"{base_url}/{name}"
        new_path = path.replace("private/google-modules/", "google-modules/")

        add_git_subtree(name, new_path, repo_url, revision)

    print("All specified modules have been processed.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fetch and add kernel modules using git subtree.")
    parser.add_argument("-m", "--manifest", required=True, help="Path to the input manifest XML file")
    args = parser.parse_args()

    if not os.path.isfile(args.manifest):
        sys.exit(f"Error: File '{args.manifest}' not found.")

    process_manifest(args.manifest)
