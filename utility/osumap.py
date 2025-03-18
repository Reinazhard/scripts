# This script fetches download URLs for osu! beatmap packs and optionally downloads them using aria2c.
# It detects the appropriate file format (.zip or .7z) for each beatmap pack and writes the URLs to a file.
# The user can choose to immediately start downloading the packs with aria2c or save the file for manual use later.
# Make sure to install aiohttp python module.

import asyncio
import aiohttp
import subprocess
import logging
import argparse
from aiohttp import ClientTimeout

# Define the log format
log_format = "%(levelname)s: %(message)s"

# Parse command-line arguments
parser = argparse.ArgumentParser(description="Fetch and download osu! beatmap packs")
parser.add_argument(
    "-d",
    "--debug",
    action="store_true",
    help="Enable higher level debugging with date and time",
)
args = parser.parse_args()

# Set logging configuration based on debug argument
if args.debug:
    logging.basicConfig(
        level=logging.DEBUG, format="%(asctime)s - %(levelname)s - %(message)s"
    )
else:
    logging.basicConfig(level=logging.INFO, format=log_format)


async def detect_file_format(session, number):
    """
    Detects the file format (.zip or .7z) for a given beatmap pack number by checking the URL.

    Args:
        session: The aiohttp ClientSession object.
        number: The beatmap pack number.

    Returns:
        The URL of the detected file format or None if not found.
    """
    base_url_new = (
        f"https://packs.ppy.sh/S{number}%20-%20osu%21%20Beatmap%20Pack%20%23{number}"
    )
    base_url_old = f"https://packs.ppy.sh/S{number}%20-%20Beatmap%20Pack%20%23{number}"

    for base_url in [base_url_new, base_url_old]:
        for ext in [".zip", ".7z"]:
            url = base_url + ext
            for attempt in range(3):  # Retry logic
                try:
                    async with session.head(url) as response:
                        if response.status == 200:
                            return url
                except asyncio.TimeoutError:
                    logging.warning(f"Timeout for {url} (attempt {attempt + 1}/3)")
                except aiohttp.ClientError as e:
                    logging.error(f"Error for {url}: {e} (attempt {attempt + 1}/3)")
                await asyncio.sleep(1)  # Backoff between retries
    return None


async def fetch_urls(start, end):
    """
    Fetches URLs for beatmap packs in the specified range.

    Args:
        start: The starting beatmap pack number.
        end: The ending beatmap pack number.

    Returns:
        A dictionary of beatmap pack numbers and their corresponding URLs.
    """
    urls = {}

    async def fetch_url(session, number):
        url = await detect_file_format(session, number)
        urls[number] = url
        if url:
            logging.info(f"Detected: {url}")
        else:
            logging.warning(f"No file found for S{number}")

    timeout = ClientTimeout(total=30)  # Set global timeout for all requests
    connector = aiohttp.TCPConnector(limit=20)  # Limit concurrent connections
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        tasks = [fetch_url(session, number) for number in range(start, end + 1)]
        await asyncio.gather(*tasks)

    return urls


def save_urls_to_file(urls, output_file):
    """
    Saves the detected URLs to a file.

    Args:
        urls: A dictionary of beatmap pack numbers and their corresponding URLs.
        output_file: The file path to save the URLs.
    """
    with open(output_file, "w") as file:
        for number, url in urls.items():
            if url:
                file.write(url + "\n")
    logging.info(f"URLs successfully saved to {output_file}.")


def fetch_and_download_osu_maps():
    """
    Main function to fetch and optionally download osu! beatmap packs.
    """
    try:
        start = int(input("Enter the starting beatmap pack number: ").strip())
        end = int(input("Enter the ending beatmap pack number: ").strip())
        if start > end:
            logging.error(
                "Error: The starting number should be less than or equal to the ending number."
            )
            return
    except ValueError:
        logging.error("Error: Please enter valid integers for the range.")
        return

    output_file = "osu_map_downloads.txt"

    # Run the async fetcher
    urls = asyncio.run(fetch_urls(start, end))

    # Save URLs to file
    save_urls_to_file(urls, output_file)

    # Optionally start aria2c
    start_aria2c = (
        input("Do you want to start aria2c to download the maps? (yes/no): ")
        .strip()
        .lower()
    )
    if start_aria2c in ["yes", "y"]:
        logging.info("Starting aria2c...")
        subprocess.run(["aria2c", "-i", output_file])
    else:
        logging.info(
            "aria2c was not started. You can use the file later to download manually."
        )


# Run the script
if __name__ == "__main__":
    fetch_and_download_osu_maps()
