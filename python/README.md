# Nutrition Scanner — Python SDK

Server-side client (manual capture only — servers have no camera). Ideal for
batch processing, backend integrations, and tests.

## Install

```bash
pip install requests
```

Copy [`nutrition_scanner.py`](nutrition_scanner.py) into your project.

## Usage

```python
from nutrition_scanner import NutritionScanner, ScanError

scanner = NutritionScanner(api_key="nls_...")  # or env NUTRITION_SCANNER_API_KEY

result = scanner.scan("label.jpg")             # path, bytes, or file-like
if result["entities"]:
    kcal = result["nutriments"]["energy_kcal_100g"]
    print(kcal["value"], kcal["unit"])         # 449.0 kcal
else:
    print("No nutrition table found in this image.")
```

Errors raise `ScanError` with `.status` and `.detail`
(401 bad/revoked key, 400 undecodable image, 5xx transient — retry with
backoff). `scanner.health()` returns the service health.

Keep images at 1200–2000 px on the long side for best speed; JPEG, PNG, and
HEIC are accepted. Typical latency is 3–4 s per image; the client allows 60 s
to survive rare cold starts. Store the API key in your secret manager, not in
code.
