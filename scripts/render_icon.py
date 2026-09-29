# Рендер иконки из макета (app-icon.html) в Resources/AppIcon-1024.png. Нужен: pip install playwright && playwright install chromium
from playwright.sync_api import sync_playwright
import pathlib
p = pathlib.Path(__file__).parent
with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_page(viewport={'width':1024,'height':1024})
    page.goto('file://' + str(p/'app-icon.html'))
    page.screenshot(path=str(p/'../Resources/AppIcon-1024.png'), omit_background=True)
    b.close()
