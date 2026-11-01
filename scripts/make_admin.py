"""Grant admin to a registered user: python -m scripts.make_admin me@example.com"""
import sys

import psycopg

from housefull.config import DATABASE_URL


def main() -> None:
    email = sys.argv[1].lower()
    with psycopg.connect(DATABASE_URL) as conn:
        updated = conn.execute(
            "UPDATE users SET is_admin = true WHERE email = %s", (email,)
        ).rowcount
    if not updated:
        sys.exit(f"no user registered with {email}")
    print(f"{email} is now an admin")


if __name__ == "__main__":
    main()
