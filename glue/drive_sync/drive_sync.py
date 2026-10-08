"""drive_sync: copy new or changed CSV files from a Google Drive folder into S3 (bronze)."""

from dataclasses import dataclass
from typing import Optional

FOLDER_MIME_TYPE = "application/vnd.google-apps.folder"
FILE_FIELDS = (
    "nextPageToken, files(id, name, mimeType, md5Checksum, modifiedTime, size)"
)


@dataclass(frozen=True)
class DriveFile:
    """One file in the Drive folder, with its path relative to the top folder."""

    file_id: str
    name: str
    path: str
    mime_type: str
    md5: Optional[str]
    modified_time: str
    size: int


def list_files(drive, folder_id: str, prefix: str = "") -> list[DriveFile]:
    """Return every file under a Drive folder, including subfolders, following pagination."""
    files = []
    page_token = None
    while True:
        response = (
            drive.files()
            .list(
                q=f"'{folder_id}' in parents and trashed = false",
                fields=FILE_FIELDS,
                pageToken=page_token,
                pageSize=1000,
            )
            .execute()
        )
        for item in response.get("files", []):
            path = f"{prefix}{item['name']}"
            if item["mimeType"] == FOLDER_MIME_TYPE:
                files.extend(list_files(drive, item["id"], prefix=f"{path}/"))
            else:
                files.append(
                    DriveFile(
                        file_id=item["id"],
                        name=item["name"],
                        path=path,
                        mime_type=item["mimeType"],
                        md5=item.get("md5Checksum"),
                        modified_time=item["modifiedTime"],
                        size=int(item.get("size", 0)),
                    )
                )
        page_token = response.get("nextPageToken")
        if not page_token:
            return files
