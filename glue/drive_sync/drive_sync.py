"""drive_sync: copy new or changed CSV files from a Google Drive folder into S3 (bronze)."""

import hashlib
import re
import tempfile

from googleapiclient.http import MediaIoBaseDownload

FOLDER_MIME_TYPE = "application/vnd.google-apps.folder"
FIELDS = "nextPageToken, files(id, name, mimeType, md5Checksum)"
CHUNK_SIZE = 8 * 1024 * 1024  # Download in 8 MB chunks


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
