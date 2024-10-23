main = lambda data: data.get("bootstrap_cloudflare.external", {}).get("enabled", False) == True
