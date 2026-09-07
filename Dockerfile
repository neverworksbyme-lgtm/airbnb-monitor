import asyncio
import json
import os
import smtplib
import sys
from datetime import datetime
from email.mime.text import MIMEText
from pathlib import Path
from playwright.async_api import async_playwright

# ----------------------------- SEARCH SETTINGS -----------------------------
LOCATION = "Reunion Resort, Reunion, FL"
CHECKIN = "2026-09-22"
CHECKOUT = "2026-10-04"
MIN_BEDROOMS = 5
MAX_PRICE = 4000
ADULTS = 10
CHECK_INTERVAL_SECONDS = 120
STATE_FILE = Path(__file__).parent / "seen_listings.json"

# ----------------------------- EMAIL SETTINGS -------------------------------
GMAIL_ADDRESS = os.environ.get("GMAIL_ADDRESS")
GMAIL_APP_PASSWORD = os.environ.get("GMAIL_APP_PASSWORD")
ALERT_TO_EMAIL = os.environ.get("ALERT_TO_EMAIL", GMAIL_ADDRESS)

# ----------------------------- SELECTOR CONSTANTS ---------------------------
# Fallback selectors to account for Airbnb DOM variations
LISTING_CARD_SELECTOR = 'div[itemprop="itemListElement"], div[data-testid="card-container"]'
LISTING_LINK_SELECTOR = 'a[href*="/rooms/"]'
LISTING_TITLE_SELECTOR = 'div[data-testid="listing-card-title"], span[id*="title"]'
LISTING_PRICE_SELECTOR = 'span[data-testid="price-availability-row"], span._1y74zjx'


def build_search_url() -> str:
    from urllib.parse import quote

    loc = quote(LOCATION)
    return (
        f"https://www.airbnb.com/s/{loc}/homes"
        f"?checkin={CHECKIN}&checkout={CHECKOUT}"
        f"&adults={ADULTS}"
        f"&min_bedrooms={MIN_BEDROOMS}"
        f"&price_max={MAX_PRICE}"
    )


def load_seen_ids() -> set:
    if STATE_FILE.exists():
        try:
            return set(json.loads(STATE_FILE.read_text()))
        except Exception:
            return set()
    return set()


def save_seen_ids(ids: set) -> None:
    STATE_FILE.write_text(json.dumps(sorted(ids)))


def send_email(subject: str, body: str) -> None:
    if not (GMAIL_ADDRESS and GMAIL_APP_PASSWORD and ALERT_TO_EMAIL):
        print("[!] Email env vars not set — skipping email, printing instead:")
        print(subject)
        print(body)
        return

    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = GMAIL_ADDRESS
    msg["To"] = ALERT_TO_EMAIL

    try:
        with smtplib.SMTP_SSL("smtp.gmail.com", 465) as server:
            server.login(GMAIL_ADDRESS, GMAIL_APP_PASSWORD)
            server.sendmail(GMAIL_ADDRESS, [ALERT_TO_EMAIL], msg.as_string())
        print(f"[{datetime.now()}] Email sent: {subject}")
    except Exception as e:
        print(f"[!] Failed to send email: {e}")


async def fetch_listings(playwright) -> list:
    """Returns a list of dicts: {id, title, price, url}"""
    # Removed redundant os.system("playwright install chromium") call
    browser = await playwright.chromium.launch(headless=True)
    context = await browser.new_context(
        user_agent=(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        )
    )
    page = await context.new_page()
    url = build_search_url()
    listings = []

    try:
        await page.goto(url, timeout=30000, wait_until="domcontentloaded")
        await page.wait_for_timeout(4000)

        cards = await page.query_selector_all(LISTING_CARD_SELECTOR)
        for card in cards:
            link_el = await card.query_selector(LISTING_LINK_SELECTOR)
            if not link_el:
                continue

            href = await link_el.get_attribute("href")
            if not href:
                continue

            listing_id = href.split("/rooms/")[-1].split("?")[0]
            title_el = await card.query_selector(LISTING_TITLE_SELECTOR)
            title = (await title_el.inner_text()) if title_el else "(title unavailable)"

            price_el = await card.query_selector(LISTING_PRICE_SELECTOR)
            price = (await price_el.inner_text()) if price_el else "(price unavailable)"

            listings.append(
                {
                    "id": listing_id,
                    "title": title.strip(),
                    "price": price.strip(),
                    "url": f"https://www.airbnb.com/rooms/{listing_id}",
                }
            )
    finally:
        await browser.close()

    return listings


async def check_once(playwright) -> None:
    seen = load_seen_ids()
    try:
        listings = await fetch_listings(playwright)
    except Exception as e:
        print(f"[{datetime.now()}] Fetch error: {e}")
        return

    if not listings:
        print(
            f"[{datetime.now()}] No listings parsed this check "
            f"(could be a genuine zero-result search, or Airbnb blocking/changed layout)."
        )
        return

    current_ids = {l["id"] for l in listings}
    new_ids = current_ids - seen

    if new_ids:
        new_listings = [l for l in listings if l["id"] in new_ids]
        body_lines = [f"{l['title']} — {l['price']}\n{l['url']}\n" for l in new_listings]
        send_email(
            subject=f"🏠 {len(new_listings)} new Airbnb listing(s) found",
            body="\n".join(body_lines),
        )

    save_seen_ids(seen | current_ids)


async def main():
    if not (GMAIL_ADDRESS and GMAIL_APP_PASSWORD):
        print(
            "[!] WARNING: GMAIL_ADDRESS / GMAIL_APP_PASSWORD not set. "
            "Alerts will just print to console instead of emailing.\n"
        )

    async with async_playwright() as playwright:
        if not STATE_FILE.exists():
            print("First run: recording current listings as baseline (no alert sent)...")
            try:
                listings = await fetch_listings(playwright)
                save_seen_ids({l["id"] for l in listings})
                print(f"Baseline recorded: {len(listings)} listings.")
            except Exception as e:
                print(f"Failed to record baseline: {e}")

        while True:
            try:
                await check_once(playwright)
            except Exception as e:
                print(f"[{datetime.now()}] Unexpected execution error: {e}")
            await asyncio.sleep(CHECK_INTERVAL_SECONDS)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
