import os


class Config:
    def __init__(self):
        self.openai_api_key = os.environ["OPENAI_API_KEY"]
        self.telegram_token = os.environ["TELEGRAM_TOKEN"]
        self.internal_api_token = os.environ["INTERNAL_API_TOKEN"].strip()
        if len(self.internal_api_token) < 16:
            raise ValueError("INTERNAL_API_TOKEN must contain at least 16 characters")
        self.telegram_allowed_users = [
            int(uid.strip())
            for uid in os.environ["TELEGRAM_ALLOWED_USERS"].split(",")
            if uid.strip()
        ]
        self.workers = int(os.environ.get("WORKERS", "3"))
        self.telegram_api_url = os.environ.get("TELEGRAM_API_URL")
        self.http_port = int(os.environ.get("HTTP_PORT", "8080"))
        self.shared_dir = os.environ.get("SHARED_DIR", "/shared")
        self.discord_callback_url = os.environ.get(
            "DISCORD_CALLBACK_URL", "http://discord-bot:3100/callback"
        )
        self.telegram_fallback_chats = [
            int(cid.strip())
            for cid in os.environ.get("TELEGRAM_FALLBACK_CHATS", "").split(",")
            if cid.strip()
        ]


config = Config()
