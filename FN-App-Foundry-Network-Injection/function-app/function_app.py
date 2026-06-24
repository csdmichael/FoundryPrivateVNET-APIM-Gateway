"""Private Data Function App (Azure Functions Python v2 model) — network-injection edition.

Serves read-only product catalog, inventory, and order data over HTTP. The app is
deployed with public network access **disabled** (no selected networks, no public
access) and is reachable only through a private endpoint inside the VNet.

Unlike the APIM-fronted edition, an Azure AI Foundry agent consumes these APIs
**directly** over the private network: the Foundry account uses **virtual network
injection** so the agent's compute runs inside the same VNet and resolves the
Function App's private IP through private DNS. There is no APIM gateway hop and no
token exchange — the private network boundary is the access control.

All routes are anonymous at the function layer; access is enforced by the private
network boundary (private endpoint + disabled public access).
"""

import datetime
import json
import os

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

_BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_DATA_PATH = os.path.join(_BASE_DIR, "data", "catalog.json")
_OPENAPI_PATH = os.path.join(_BASE_DIR, "openapi.json")


def _load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _json_response(payload, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload),
        status_code=status_code,
        mimetype="application/json",
    )


def _data() -> dict:
    # Loaded per request so packaged data updates are picked up without restart.
    return _load_json(_DATA_PATH)


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    return _json_response(
        {
            "status": "healthy",
            "service": "foundry-data-function-ni-api",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
    )


@app.route(route="products", methods=["GET"])
def list_products(req: func.HttpRequest) -> func.HttpResponse:
    products = _data()["products"]
    category = req.params.get("category")
    if category:
        products = [p for p in products if p["category"] == category]
    return _json_response(products)


@app.route(route="products/{productId}", methods=["GET"])
def get_product(req: func.HttpRequest) -> func.HttpResponse:
    product_id = req.route_params.get("productId")
    product = next((p for p in _data()["products"] if p["productId"] == product_id), None)
    if product is None:
        return _json_response({"error": f"Product {product_id} not found"}, status_code=404)
    return _json_response(product)


@app.route(route="categories", methods=["GET"])
def list_categories(req: func.HttpRequest) -> func.HttpResponse:
    data = _data()
    counts: dict[str, int] = {}
    for product in data["products"]:
        counts[product["category"]] = counts.get(product["category"], 0) + 1
    categories = [
        {
            "category": c["category"],
            "displayName": c["displayName"],
            "productCount": counts.get(c["category"], 0),
        }
        for c in data["categories"]
    ]
    return _json_response(categories)


@app.route(route="inventory/{productId}", methods=["GET"])
def get_inventory(req: func.HttpRequest) -> func.HttpResponse:
    product_id = req.route_params.get("productId")
    record = _data()["inventory"].get(product_id)
    if record is None:
        return _json_response({"error": f"Inventory for {product_id} not found"}, status_code=404)
    return _json_response({"productId": product_id, **record})


@app.route(route="orders", methods=["GET"])
def list_orders(req: func.HttpRequest) -> func.HttpResponse:
    orders = _data()["orders"]
    status = req.params.get("status")
    if status:
        orders = [o for o in orders if o["status"] == status]
    return _json_response(orders)


@app.route(route="openapi.json", methods=["GET"])
def openapi(req: func.HttpRequest) -> func.HttpResponse:
    spec = _load_json(_OPENAPI_PATH)
    # Rewrite the server URL to the caller's host so Swagger UI "Try it out" and
    # downstream importers resolve the correct base (the private function host).
    forwarded_host = req.headers.get("x-forwarded-host") or req.headers.get("host")
    if forwarded_host:
        scheme = req.headers.get("x-forwarded-proto", "https")
        spec["servers"] = [{"url": f"{scheme}://{forwarded_host}", "description": "Resolved from request host"}]
    return _json_response(spec)


@app.route(route="swagger", methods=["GET"])
def swagger_ui(req: func.HttpRequest) -> func.HttpResponse:
    html = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Foundry Data Function API (Network Injection) - Swagger UI</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css" />
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    window.onload = function () {
      window.ui = SwaggerUIBundle({
        url: 'openapi.json',
        dom_id: '#swagger-ui',
        deepLinking: true,
        presets: [SwaggerUIBundle.presets.apis]
      });
    };
  </script>
</body>
</html>"""
    return func.HttpResponse(html, status_code=200, mimetype="text/html")
