"""Tests for listing a Drive folder: subfolders and pagination."""

from drive_sync import FOLDER_MIME_TYPE, list_files


def item(name, mime_type="text/csv", file_id=None):
    """Build a fake Drive API file record."""
    return {
        "id": file_id or name,
        "name": name,
        "mimeType": mime_type,
        "md5Checksum": "0123abcd",
        "modifiedTime": "2026-10-01T00:00:00.000Z",
        "size": "10",
    }


class FakeDrive:
    """Stands in for the Google Drive client: drive.files().list(...).execute().

    pages_by_folder maps a folder ID to its pages of results: {folder_id: [page_1, page_2, ...]}.
    """

    def __init__(self, pages_by_folder):
        self.pages_by_folder = pages_by_folder
        self._response = None

    def files(self):
        return self

    def list(self, q, fields, pageToken=None, pageSize=None):
        folder_id = q.split("'")[1]
        page_number = int(pageToken or 0)
        pages = self.pages_by_folder[folder_id]
        self._response = {"files": pages[page_number]}
        if page_number + 1 < len(pages):
            self._response["nextPageToken"] = str(page_number + 1)
        return self

    def execute(self):
        return self._response


def test_lists_files_in_subfolders_with_paths():
    drive = FakeDrive(
        {
            "top": [
                [
                    item("PBJ.csv"),
                    item("Nursing_Home_data", FOLDER_MIME_TYPE, file_id="sub"),
                ]
            ],
            "sub": [
                [
                    item("NH_ProviderInfo.csv"),
                    item("NH_Data_Dictionary.pdf", "application/pdf"),
                ]
            ],
        }
    )

    files = list_files(drive, "top")

    assert sorted(f.path for f in files) == [
        "Nursing_Home_data/NH_Data_Dictionary.pdf",
        "Nursing_Home_data/NH_ProviderInfo.csv",
        "PBJ.csv",
    ]


def test_follows_pagination():
    drive = FakeDrive(
        {
            "top": [
                [item("a.csv")],
                [item("b.csv")],
            ]
        }
    )

    files = list_files(drive, "top")

    assert sorted(f.name for f in files) == ["a.csv", "b.csv"]
