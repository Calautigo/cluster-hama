main = lambda data: data.get("bootstrap_cloudflare.tunnel", {}).get("enabled", False) == True
