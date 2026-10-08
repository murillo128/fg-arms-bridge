#!/usr/bin/env python3
"""Exercise the actual UI with Playwright. Default mode uses a local HTTP origin.
--embedded renders local bytes without navigation; it does not certify HTTP,
persistent browser storage or URL navigation. Those checks run in default CI.
"""
import argparse
import base64
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import threading
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parents[1] / 'docs'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--embedded',action='store_true')
    parser.add_argument('--chromium')
    parser.add_argument('--screenshots',type=Path)
    args=parser.parse_args()
    server=None
    if not args.embedded:
        server=ThreadingHTTPServer(('127.0.0.1',0),functools.partial(SimpleHTTPRequestHandler,directory=str(ROOT)))
        threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with sync_playwright() as p:
            launch={'headless':True}
            if args.chromium:launch['executable_path']=args.chromium
            browser=p.chromium.launch(**launch)
            context=browser.new_context(viewport={'width':1480,'height':1100},accept_downloads=True)
            page=context.new_page();errors=[]
            page.on('pageerror',lambda e:errors.append(str(e)))
            if args.embedded:
                html=(ROOT/'index.html').read_text()
                html=re.sub(r'<script defer src="[^"]+"></script>','',html)
                html=html.replace('<link rel="stylesheet" href="simulator/style.css">','<style>'+(ROOT/'simulator/style.css').read_text()+'</style>')
                html=html.replace('simulator/logo.png','data:image/png;base64,'+base64.b64encode((ROOT/'simulator/logo.png').read_bytes()).decode())
                page.set_content(html)
                for script in ['data.js','engine.js','app.js']:page.add_script_tag(content=(ROOT/'simulator'/script).read_text())
                print('Embedded DOM mode: HTTP, persistent storage and URL navigation not certified here.')
            else:
                url=f'http://127.0.0.1:{server.server_port}/'
                page.goto(url,wait_until='networkidle')
            expect(page.locator('#rows tr')).to_have_count(20)
            expect(page.locator('#metrics')).to_contain_text('5,51')
            expect(page.locator('#metrics')).to_contain_text('4,32')
            page.select_option('#weapon','greataxe');expect(page.locator('#hands')).to_have_value('2h')
            page.click('#reset');page.fill('#attackOther','3')
            expect(page.locator('#attack-formula')).to_contain_text('+10')
            page.click('#reset');page.click('#add-extra')
            page.locator('.extra-row').nth(1).locator('select').select_option('fire')
            expect(page.locator('[data-roll="15"]')).to_contain_text('10,75')
            page.locator('[data-remove="1"]').click()
            expect(page.locator('[data-roll="15"]')).to_contain_text('9,50')
            page.locator('.extra-row input[type=text]').fill('alert(1)')
            expect(page.locator('#error')).to_be_visible();expect(page.locator('#results')).to_be_hidden()
            page.locator('.extra-row input[type=text]').fill('1d4')
            expect(page.locator('#error')).to_be_hidden()
            page.locator('#defenses details').nth(1).locator('summary').click()
            page.locator('[data-defense="immune"][value="slashing"]').check()
            expect(page.locator('#metrics')).not_to_contain_text('∞')
            page.click('#reset');page.click('[data-roll="20"] button');page.check('#branch')
            page.fill('#chain-count','2');page.locator('#chain-count').press('Tab')
            expect(page.locator('#detail')).to_contain_text('Suplemento +13')
            page.click('#tab-global');expect(page.locator('#global-chart svg')).to_be_visible()
            page.click('#tab-sensitivity');expect(page.locator('#sensitivity-chart tbody tr')).to_have_count(11)
            page.click('#tab-rolls');page.click('#armory')
            page.fill('#armory-search','espada larga');page.click('[data-choose="longsword"]')
            expect(page.locator('#modal')).not_to_be_visible()
            page.click('#rules');expect(page.locator('#modal')).to_be_visible();page.keyboard.press('Escape')
            page.click('#reset')
            with page.expect_download() as downloaded:page.click('#csv')
            downloaded.value.save_as('/tmp/arms-simulator-browser.csv')
            assert len(Path('/tmp/arms-simulator-browser.csv').read_text().splitlines())==21
            if not args.embedded:
                page.fill('#attackOther','3');page.click('#save');page.click('#reset');page.click('#load')
                expect(page.locator('#attackOther')).to_have_value('3')
                link=page.evaluate('location.href.split("#")[0]+ArmsSimulator.encode({...ArmsSimulator.defaults,weapon:"rapier"})')
                page.goto(link,wait_until='networkidle');expect(page.locator('#weapon')).to_have_value('rapier')
                page.click('#share')
                page.wait_for_function("document.getElementById('modal').open || document.getElementById('message').textContent.includes('copiado')")
                # Clipboard availability is browser-dependent; the fallback is a selectable URL.
                if page.locator('#modal').is_visible():
                    assert '#s=' in page.locator('#share-url').input_value();page.click('#close-modal')
                else:expect(page.locator('#message')).to_contain_text('copiado')
            page.click('#reset')
            if args.screenshots:
                args.screenshots.mkdir(parents=True,exist_ok=True)
                page.screenshot(path=str(args.screenshots/'simulator-desktop.png'),full_page=True)
            page.set_viewport_size({'width':390,'height':844})
            assert page.evaluate('document.documentElement.scrollWidth <= document.documentElement.clientWidth+1')
            assert page.locator('.table-scroll').evaluate('(e)=>e.scrollWidth>e.clientWidth')
            page.locator('[data-roll="15"] button').click()
            expect(page.locator('#detail')).to_contain_text('9,00')
            if args.screenshots:page.screenshot(path=str(args.screenshots/'simulator-mobile.png'),full_page=True)
            assert not errors,errors
            browser.close()
            print('PASS browser: controls, calculation, typed components, validation, open chain, views, catalog, CSV, keyboard/modal and mobile layout.')
            if not args.embedded:print('PASS HTTP assets, local save/load, scenario URL navigation and share UI.')
    finally:
        if server:server.shutdown()


if __name__=='__main__':main()
