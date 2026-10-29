// Activates (or re-activates) a CML constraint model version through the Constraint Builder, the only path that
// compiles the uploaded CML into the runtime model. Setting ExpressionSetVersion.IsActive over the API flips the flag
// but leaves the configurator running the previously compiled model.
//
//   node scripts/cml/nf_cml_activate.mjs <expressionSetId> <versionId> <versionName> <contextDefinitionId>
//
// Prints the builder's toast; exits 1 unless it reports "Constraint model activated". Called by nf_cml.py.
import { chromium } from 'playwright';
import { execSync } from 'node:child_process';

const [, , esId, versionId, versionName, contextId] = process.argv;
const ORG = process.env.NF_ORG || 'RCPOC';
const frontdoor = JSON.parse(execSync(`sf org open -o ${ORG} -r --json`).toString()).result.url;
const lightning = new URL(frontdoor).origin.replace('.my.salesforce.com', '.lightning.force.com');
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1500, height: 950 } });

async function idle() {
    await page.locator('lightning-spinner').first().waitFor({ state: 'hidden', timeout: 120000 }).catch(() => {});
}
const shot = (name) => (process.env.NF_DEBUG ? page.screenshot({ path: `cml_${name}.png` }) : Promise.resolve());
async function click(label) {
    await idle();
    await shot(`before_${label}`);
    await page.getByRole('button', { name: label, exact: true }).first().click({ force: true });
    await page.waitForTimeout(3000);
    await shot(`after_${label}`);
    const confirm = page.locator('section[role=dialog] button, .slds-modal button').filter({ hasText: new RegExp(`^(${label}|OK|Confirm)$`) });
    if (await confirm.count()) await confirm.first().click();
    for (let t = 0; t < 20; t++) {
        await page.waitForTimeout(1500);
        const text = (await page.locator('.slds-notify, [role=alert]').allInnerTexts().catch(() => [])).join(' ').replace(/\s+/g, ' ');
        if (text.trim()) return text;
    }
    return '';
}

let ok = false;
try {
    await page.goto(frontdoor, { waitUntil: 'domcontentloaded', timeout: 120000 });
    await page.waitForTimeout(4000);
    const url = `${lightning}/builder_industries_constraints/constraintBuilder.app?constraintId=${esId}&versionId=${versionId}`
        + `&versionName=${encodeURIComponent(versionName)}&contextId=${contextId}`;
    await page.goto(url, { waitUntil: 'commit', timeout: 120000 });
    await page.waitForTimeout(10000);
    await idle();
    if (await page.getByRole('button', { name: 'Deactivate', exact: true }).count()) {
        console.log('Deactivate: ' + (await click('Deactivate')).slice(0, 300));
        await page.locator('.slds-notify button[title=Close], .slds-notify .slds-notify__close button').first().click().catch(() => {});
    }
    const toast = await click('Activate');
    console.log('Activate: ' + toast.slice(0, 1500));
    ok = /Constraint model activated/i.test(toast);
} finally {
    await browser.close();
}
process.exit(ok ? 0 : 1);
