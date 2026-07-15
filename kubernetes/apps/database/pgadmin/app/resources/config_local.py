import os

# OIDC-only auth via Pocket-ID; client credentials come from the
# pgadmin-oidc secret (envFrom in the pgadmin container), never written here.
AUTHENTICATION_SOURCES = ["oauth2"]
OAUTH2_AUTO_CREATE_USER = True
OAUTH2_CONFIG = [
    {
        "OAUTH2_NAME": "pocketid",
        "OAUTH2_DISPLAY_NAME": "Pocket ID",
        "OAUTH2_CLIENT_ID": os.environ["OIDC_CLIENT_ID"],
        "OAUTH2_CLIENT_SECRET": os.environ["OIDC_CLIENT_SECRET"],
        "OAUTH2_SERVER_METADATA_URL": os.environ["OIDC_ISSUER_URL"]
        + "/.well-known/openid-configuration",
        "OAUTH2_SCOPE": "openid email profile",
        "OAUTH2_ICON": "fa-key",
        "OAUTH2_BUTTON_COLOR": "#635bff",
    }
]
