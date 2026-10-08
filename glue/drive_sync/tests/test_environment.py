"""Smoke test: the job's environment matches what AWS Glue Python shell expects."""

import sys


def test_python_version_matches_glue():
    """Test that the Python version matches what AWS Glue Python shell expects."""
    assert sys.version_info[:2] == (
        3,
        9,
    ), f"Expected Python 3.9, but got {sys.version_info[:2]}"


def test_google_client_installed():
    """Test that the google-api-python-client package is installed."""
    import googleapiclient
