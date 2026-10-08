"""drive_sync: copy new or changed CSV files from a Google Drive folder into S3 (bronze)."""

import argparse
import hashlib
import json
import logging
import re
import sys
import tempfile
from datetime import datetime, timezone

import boto3
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

FOLDER_MIME_TYPE = "application/vnd.google-apps.folder"
FIELDS = "nextPageToken, files(id, name, mimeType, md5Checksum)"
CHUNK_SIZE = 8 * 1024 * 1024  # Download in 8 MB chunks

DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.readonly"

log = logging.getLogger("drive_sync")


def list_csv_files(drive, folder_id: str) -> list[dict]:
    """Return every CSV file under a Drive folder, including its subfolders."""
    files = []
    query = f"'{folder_id}' in parents and trashed = false"
    page_token = None
    while True:
        request = drive.files().list(q=query, fields=FIELDS, pageToken=page_token)
        response = request.execute()
        for item in response["files"]:
            if item["mimeType"] == FOLDER_MIME_TYPE:
                files += list_csv_files(drive, item["id"])
            elif item["name"].lower().endswith(".csv"):
                files.append(item)
        page_token = response.get("nextPageToken")
        if not page_token:
            return files


def files_to_copy(files: list[dict], manifest: dict[str, dict]) -> list[dict]:
    """Return the files that are new or changed since they were last copied."""
    return [
        file
        for file in files
        if manifest.get(file["id"], {}).get("md5") != file["md5Checksum"]
    ]


def s3_key(file_name: str, ingest_date: str) -> str:
    """Return the bronze key raw/<dataset>/ingest_date=YYYY-MM-DD/<file name>.

    The dataset is the file name in snake_case: NH_ProviderInfo_Oct2024.csv -> nh_provider_info_oct2024.
    """
    stem = file_name.rsplit(".", 1)[0]
    stem = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", stem)
    dataset = re.sub(r"[^a-z0-9]+", "_", stem.lower()).strip("_")
    return f"raw/{dataset}/ingest_date={ingest_date}/{file_name}"


def copy_file(drive, s3, table, file: dict, bucket: str, ingest_date: str) -> None:
    """Copy one Drive file to S3 as UTF-8, verify its MD5, then mark it LANDED."""
    key = s3_key(file["name"], ingest_date)
    with tempfile.TemporaryFile() as original, tempfile.TemporaryFile() as utf8:
        request = drive.files().get_media(fileId=file["id"])
        downloader = MediaIoBaseDownload(original, request, chunksize=CHUNK_SIZE)
        done = False
        while not done:
            _, done = downloader.next_chunk(num_retries=5)

        original.seek(0)
        digest = hashlib.md5()
        for line in original:
            digest.update(line)
            try:
                text = line.decode("utf-8")
            except UnicodeDecodeError:
                text = line.decode("cp1252")
            utf8.write(text.encode("utf-8"))

        md5 = digest.hexdigest()
        if md5 != file["md5Checksum"]:
            raise ValueError(
                f"MD5 mismatch for {file['name']}: Drive {file['md5Checksum']}, got {md5}"
            )

        utf8.seek(0)
        s3.upload_fileobj(utf8, bucket, key)

    table.put_item(
        Item={
            "drive_file_id": file["id"],
            "file_name": file["name"],
            "md5": md5,
            "s3_key": key,
            "status": "LANDED",
        }
    )


def parse_args() -> argparse.Namespace:
    """Read the job settings. Glue passes them as --name value, like a command line."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--folder_id", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--manifest_table", required=True)
    parser.add_argument("--secret_name", required=True)
    parser.add_argument("--region", default="us-west-2")
    args, _ = parser.parse_known_args()
    return args


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stdout,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    args = parse_args()

    secrets = boto3.client("secretsmanager", region_name=args.region)
    key_json = secrets.get_secret_value(SecretId=args.secret_name)["SecretString"]
    credentials = service_account.Credentials.from_service_account_info(
        json.loads(key_json), scopes=[DRIVE_SCOPE]
    )
    drive = build("drive", "v3", credentials=credentials, cache_discovery=False)
    s3 = boto3.client("s3", region_name=args.region)
    table = boto3.resource("dynamodb", region_name=args.region).Table(
        args.manifest_table
    )

    manifest = {item["drive_file_id"]: item for item in table.scan()["Items"]}
    files = list_csv_files(drive, args.folder_id)
    to_copy = files_to_copy(files, manifest)
    log.info("Found %d CSV files in Drive, %d new or changed", len(files), len(to_copy))

    ingest_date = datetime.now(timezone.utc).date().isoformat()
    failed = []
    for file in to_copy:
        try:
            copy_file(drive, s3, table, file, args.bucket, ingest_date)
            log.info("Copied %s", file["name"])
        except Exception:
            log.exception("Failed to copy %s", file["name"])
            failed.append(file["name"])

    if failed:
        raise RuntimeError(f"{len(failed)} of {len(to_copy)} files failed: {failed}")
    log.info("Done: copied %d files", len(to_copy))


if __name__ == "__main__":
    main()
