main = lambda data: data.get("bootstrap_cloudflare", {}).get("external", {}).get("enabled", False) == True
