"""Nutrition Scanner — Python SDK (server-side, manual capture).

    from nutrition_scanner import NutritionScanner

    scanner = NutritionScanner(api_key="nls_...")
    result = scanner.scan("label.jpg")
    print(result["nutriments"]["energy_kcal_100g"]["value"])  # 449.0

Dependency: requests.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import BinaryIO, Union

import requests

DEFAULT_BASE_URL = "https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app"


class ScanError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(f"HTTP {status}: {detail}")
        self.status = status
        self.detail = detail


class NutritionScanner:
    def __init__(
        self,
        api_key: str | None = None,
        base_url: str = DEFAULT_BASE_URL,
        timeout: float = 60.0,
    ):
        self.api_key = api_key or os.environ.get("NUTRITION_SCANNER_API_KEY")
        if not self.api_key:
            raise ValueError(
                "Pass api_key= or set NUTRITION_SCANNER_API_KEY. "
                "Keys are created in the web app's settings."
            )
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._session = requests.Session()
        self._session.headers["X-API-Key"] = self.api_key

    def scan(self, image: Union[str, Path, bytes, BinaryIO]) -> dict:
        """Scan one label image (path, bytes, or file-like). JPEG/PNG/HEIC.

        Returns the parsed response dict: entities, nutriments, words_detected.
        Empty ``entities`` means no nutrition table was found in the image —
        a normal outcome, not an error.
        """
        if isinstance(image, (str, Path)):
            payload = Path(image).read_bytes()
        elif isinstance(image, bytes):
            payload = image
        else:
            payload = image.read()

        response = self._session.post(
            f"{self.base_url}/extract",
            files={"image": ("label.jpg", payload)},
            timeout=self.timeout,
        )
        if response.status_code != 200:
            try:
                detail = response.json().get("detail", response.text)
            except ValueError:
                detail = response.text
            raise ScanError(response.status_code, detail)
        return response.json()

    def health(self) -> dict:
        return self._session.get(f"{self.base_url}/health", timeout=10).json()
