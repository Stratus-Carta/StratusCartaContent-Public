import { LightningElement, api } from 'lwc';
import { api as nfApi } from 'c/nfApi';
import { SAMPLE_ADDRESSES, US_STATES, defaultSelections, estimateItem, formatMoney, nextKey, progressFor, reduceError } from 'c/nfUtils';

const STEPS = [
    { key: 'sites', label: 'Sites' },
    { key: 'build', label: 'Plans per site' },
    { key: 'review', label: 'Review' },
    { key: 'done', label: 'Quote' }
];
const CHECK_BATCH = 10;
const MAX_SITES = 25;
const COLUMNS = ['name', 'street', 'unit', 'city', 'state', 'postalCode'];
const HEADER_ALIASES = { zip: 'postalCode', zipcode: 'postalCode', postal: 'postalCode', postalcode: 'postalCode',
    site: 'name', sitename: 'name', address: 'street', street1: 'street', suite: 'unit', apt: 'unit' };
const TEMPLATE_CSV = 'name,street,unit,city,state,postalCode\n'
    + 'HQ,350 5th Ave,Floor 12,New York,NY,10001\n'
    + 'West Coast office,415 Mission St,,San Francisco,CA,94105\n'
    + 'Chicago branch,233 S Wacker Dr,,Chicago,IL,60601\n'
    + 'Austin store,1100 Congress Ave,,Austin,TX,73301\n';

/** Minimal CSV parser: quoted fields, escaped quotes, CRLF. */
function parseCsv(text) {
    const rows = [];
    let row = [];
    let field = '';
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (quoted) {
            if (c === '"' && text[i + 1] === '"') {
                field += '"';
                i++;
            } else if (c === '"') {
                quoted = false;
            } else {
                field += c;
            }
        } else if (c === '"') {
            quoted = true;
        } else if (c === ',') {
            row.push(field);
            field = '';
        } else if (c === '\n' || c === '\r') {
            if (c === '\r' && text[i + 1] === '\n') i++;
            row.push(field);
            rows.push(row);
            row = [];
            field = '';
        } else {
            field += c;
        }
    }
    if (field || row.length) {
        row.push(field);
        rows.push(row);
    }
    return rows.filter((r) => r.some((v) => v.trim()));
}

/**
 * Multi-site quoting for agents and business visitors: upload the service locations, check each one, browse and build
 * every site's plans at its state's prices (LocationBasedDecisionTable, priced by Revenue Cloud without saving
 * anything), then create one quote with a service location and a line group per site.
 */
export default class NfMultiSite extends LightningElement {
    @api currencyCode = 'USD';
    /** Agent-selected customer { accountId, name } from the agent panel. */
    @api account;
    /** Site visitors set a portal password and accept the terms; agents open the quote and order records. */
    @api isAgent = false;

    step = 'sites';
    sites = [];
    selectedKey;
    /** { [state]: { [productId]: price } } */
    statePrices = {};
    configuring; // { offer, selections, key }
    companyName = '';
    priced; // [SiteSummary]
    quote; // MultiSiteQuote
    /** Customer contact for the order (bill-to and authorising contact). */
    contact = { firstName: '', lastName: '', email: '', phone: '', preferredInstallDate: null, portalPassword: '' };
    confirmPassword = '';
    acceptedTerms = false;
    order; // OrderResult
    showProposal = false;
    proposalSigned = false;
    proposalSigner;
    installSites = []; // [InstallSite] once the order is placed
    busy = false;
    busyMessage;
    error;
    notice;
    ruleSeq = 0; // newest background rules check (older answers are ignored)

    // ── Steps ────────────────────────────────────────────────────────────────

    get stepsView() {
        const current = STEPS.findIndex((s) => s.key === this.step);
        return STEPS.map((s, i) => ({
            ...s,
            number: i + 1,
            cssClass: 'nf-step' + (i < current ? ' nf-step_done' : '') + (i === current ? ' nf-step_current' : ''),
            ariaCurrent: i === current ? 'step' : null
        }));
    }
    get isSitesStep() {
        return this.step === 'sites';
    }
    get isBuildStep() {
        return this.step === 'build';
    }
    get isReviewStep() {
        return this.step === 'review';
    }
    get isDoneStep() {
        return this.step === 'done';
    }

    // ── Step 1: sites ────────────────────────────────────────────────────────

    get hasSites() {
        return this.sites.length > 0;
    }
    get siteCountLabel() {
        const n = this.sites.length;
        return n === 1 ? '1 site' : `${n} sites`;
    }
    get templateHref() {
        return 'data:text/csv;charset=utf-8,' + encodeURIComponent(TEMPLATE_CSV);
    }
    get sitesView() {
        return this.sites.map((s, i) => ({
            ...s,
            number: i + 1,
            addressLine: this.addressLine(s.address),
            statusLabel: this.statusLabel(s),
            statusClass: 'nf-badge' + (s.status === 'ok' ? ' nf-badge_accent' : s.status === 'error' ? ' nf-badge_warn' : ''),
            canRemove: !this.busy
        }));
    }
    get checkDisabled() {
        return this.busy || !this.sites.length;
    }
    get checkLabel() {
        return this.sites.every((s) => s.status === 'ok') && this.sites.length ? 'Continue' : 'Check sites & load prices';
    }

    addressLine(a) {
        if (!a) return '';
        return [a.unit ? `${a.street}, ${a.unit}` : a.street, a.city, `${a.state} ${a.postalCode}`].filter(Boolean).join(', ');
    }
    statusLabel(s) {
        if (s.status === 'ok') {
            const tech = (s.serviceability?.technologies || []).map((t) => t.technology).join(' + ');
            return tech || 'Mobile only';
        }
        if (s.status === 'error') return s.error || 'Not checked';
        if (s.status === 'checking') return 'Checking…';
        return 'Not checked';
    }

    handleFile(event) {
        const file = event.target.files && event.target.files[0];
        event.target.value = null;
        if (!file) return;
        const reader = new FileReader();
        reader.onload = () => this.loadCsv(String(reader.result || ''), file.name);
        reader.onerror = () => {
            this.error = 'The file could not be read.';
        };
        reader.readAsText(file);
    }

    loadCsv(text, fileName) {
        this.error = undefined;
        const rows = parseCsv(text.replace(/^﻿/, ''));
        if (rows.length < 2) {
            this.error = `${fileName} has no site rows. Use the template: name, street, unit, city, state, postalCode.`;
            return;
        }
        const header = rows[0].map((h) => {
            const k = h.trim().replace(/[\s_-]/g, '').toLowerCase();
            return HEADER_ALIASES[k] || COLUMNS.find((c) => c.toLowerCase() === k) || null;
        });
        const missing = ['street', 'city', 'state', 'postalCode'].filter((c) => !header.includes(c));
        if (missing.length) {
            this.error = `${fileName} is missing the column(s): ${missing.join(', ')}.`;
            return;
        }
        const problems = [];
        const added = [];
        rows.slice(1).forEach((r, i) => {
            const v = {};
            header.forEach((col, j) => {
                if (col) v[col] = (r[j] || '').trim();
            });
            const state = (v.state || '').toUpperCase();
            const zip = (v.postalCode || '').padStart(5, '0');
            const line = i + 2;
            if (!v.street || !v.city) {
                problems.push(`row ${line}: street and city are required`);
            } else if (!US_STATES.some((s) => s.value === state)) {   // US_STATES are combobox options
                problems.push(`row ${line}: "${v.state}" is not a 2-letter US state`);
            } else if (!/^\d{5}$/.test(zip)) {
                problems.push(`row ${line}: "${v.postalCode}" is not a 5-digit ZIP code`);
            } else {
                added.push(this.newSite(v.name || `Site ${this.sites.length + added.length + 1}`,
                    { street: v.street, unit: v.unit || '', city: v.city, state, postalCode: zip, country: 'US' }));
            }
        });
        this.addSites(added, `${added.length} site(s) loaded from ${fileName}`, problems);
    }

    handleSamples() {
        const picks = ['10001', '94105', '60601', '73301'];
        const added = SAMPLE_ADDRESSES.filter((a) => picks.includes(a.postalCode)).map((a) =>
            this.newSite(`${a.city} site`, { street: a.street, unit: '', city: a.city, state: a.state, postalCode: a.postalCode, country: 'US' }));
        this.addSites(added, `${added.length} sample sites added`, []);
    }

    addSites(added, message, problems) {
        const room = MAX_SITES - this.sites.length;
        const kept = added.slice(0, Math.max(0, room));
        this.sites = [...this.sites, ...kept];
        const notes = [message];
        if (kept.length < added.length) notes.push(`only the first ${MAX_SITES} sites are kept`);
        if (problems.length) notes.push(`${problems.length} row(s) skipped (${problems.slice(0, 3).join('; ')}${problems.length > 3 ? '; …' : ''})`);
        this.notice = notes.join(' · ');
    }

    newSite(name, address) {
        return { key: nextKey('site'), name, address, status: 'new', serviceability: null, categories: [], cart: [] };
    }

    handleRemoveSite(event) {
        const key = event.currentTarget.dataset.key;
        this.sites = this.sites.filter((s) => s.key !== key);
        if (this.selectedKey === key) this.selectedKey = this.sites[0]?.key;
    }

    handleClearSites() {
        this.sites = [];
        this.statePrices = {};
        this.notice = undefined;
    }

    /** Checks unchecked sites in batches, then loads the location prices of every state and product shown. */
    async handleCheckSites() {
        this.error = undefined;
        this.notice = undefined;
        const pending = this.sites.filter((s) => s.status !== 'ok');
        this.busy = true;
        try {
            for (let i = 0; i < pending.length; i += CHECK_BATCH) {
                const batch = pending.slice(i, i + CHECK_BATCH);
                this.busyMessage = `Checking serviceability · sites ${i + 1}–${i + batch.length} of ${pending.length}`;
                this.patchSites(batch.map((s) => s.key), { status: 'checking' });
                // eslint-disable-next-line no-await-in-loop
                const results = await nfApi.checkSites(batch.map((s) => ({ key: s.key, name: s.name, address: s.address })));
                results.forEach((r) => {
                    this.patchSites([r.key], r.error
                        ? { status: 'error', error: r.error }
                        : { status: 'ok', error: null, serviceability: r.serviceability, categories: r.offers || [] });
                });
            }
            await this.loadStatePrices();
            const ok = this.sites.filter((s) => s.status === 'ok');
            if (!ok.length) {
                this.error = 'None of the sites could be checked. Review the addresses and try again.';
                return;
            }
            this.selectedKey = this.selectedKey && ok.some((s) => s.key === this.selectedKey) ? this.selectedKey : ok[0].key;
            this.step = 'build';
            this.scrollTop();
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.busy = false;
        }
    }

    /** Location prices for every state with a checked site, for all the products those sites can buy. */
    async loadStatePrices() {
        const ok = this.sites.filter((s) => s.status === 'ok');
        const states = [...new Set(ok.map((s) => s.address.state))].filter((st) => !this.statePrices[st]);
        if (!states.length) return;
        const productIds = new Set();
        ok.forEach((s) => s.categories.forEach((c) => c.offers.forEach((o) => {
            productIds.add(o.productId);
            (o.groups || []).forEach((g) => g.options.forEach((op) => productIds.add(op.productId)));
        })));
        const prices = { ...this.statePrices };
        for (let i = 0; i < states.length; i += 10) {
            this.busyMessage = `Pricing ${states.slice(i, i + 10).join(', ')} with Revenue Cloud location prices`;
            // eslint-disable-next-line no-await-in-loop
            const result = await nfApi.statePrices({ states: states.slice(i, i + 10), productIds: [...productIds] });
            result.forEach((sp) => {
                prices[sp.state] = sp.prices || {};
            });
        }
        this.statePrices = prices;
    }

    patchSites(keys, patch) {
        this.sites = this.sites.map((s) => (keys.includes(s.key) ? { ...s, ...patch } : s));
    }

    // ── Step 2: build each site's cart ───────────────────────────────────────

    get selectedSite() {
        return this.sites.find((s) => s.key === this.selectedKey);
    }
    get selectedState() {
        return this.selectedSite?.address.state;
    }
    get selectedAddress() {
        return this.addressLine(this.selectedSite?.address);
    }
    get selectedTech() {
        return this.statusLabel(this.selectedSite || {});
    }
    get selectedServiceMessage() {
        return this.selectedSite?.serviceability?.message;
    }

    /** An offer with this state's list prices (offer and options) in place of the price book's. */
    withStatePrices(offer, state) {
        const sp = this.statePrices[state] || {};
        const at = (id, fallback) => (sp[id] !== undefined && sp[id] !== null ? sp[id] : fallback);
        return {
            ...offer,
            price: at(offer.productId, offer.price),
            groups: (offer.groups || []).map((g) => ({
                ...g,
                options: g.options.map((op) => ({ ...op, price: at(op.productId, op.price) }))
            }))
        };
    }

    get buildSites() {
        return this.sites.filter((s) => s.status === 'ok').map((s) => {
            const totals = this.cartTotals(s);
            return {
                key: s.key,
                name: s.name,
                place: `${s.address.city}, ${s.address.state}`,
                tech: this.statusLabel(s),
                itemsLabel: s.cart.length === 1 ? '1 item' : `${s.cart.length} items`,
                monthly: formatMoney(totals.monthly, this.currencyCode),
                hasItems: s.cart.length > 0,
                cssClass: 'nf-site' + (s.key === this.selectedKey ? ' nf-site_on' : '') + (s.cart.length ? ' nf-site_filled' : '')
            };
        });
    }
    get skippedSites() {
        return this.sites.filter((s) => s.status === 'error').map((s) => ({ key: s.key, name: s.name, error: s.error }));
    }
    get hasSkippedSites() {
        return this.skippedSites.length > 0;
    }

    cartTotals(site) {
        return site.cart.reduce((t, item) => {
            const e = estimateItem(item);
            return { monthly: t.monthly + e.monthly, oneTime: t.oneTime + e.oneTime };
        }, { monthly: 0, oneTime: 0 });
    }

    get categoriesView() {
        const site = this.selectedSite;
        if (!site) return [];
        const inCart = {};
        site.cart.forEach((i) => {
            inCart[i.offer.productId] = (inCart[i.offer.productId] || 0) + i.quantity;
        });
        const configuringId = this.configuring?.offer.productId;
        return site.categories.map((c) => ({
            key: c.key,
            label: c.label,
            offers: c.offers.map((o) => ({
                offer: this.withStatePrices(o, site.address.state),
                inCart: inCart[o.productId] || 0,
                showConfig: o.productId === configuringId,
                configKey: `config-${o.productId}`
            }))
        }));
    }
    get siteCartView() {
        const site = this.selectedSite;
        if (!site) return [];
        return site.cart.map((item) => {
            const e = estimateItem(item);
            const optionNames = [];
            (item.offer.groups || []).forEach((g) => g.options.forEach((op) => {
                if (item.options[op.componentId]) optionNames.push(item.options[op.componentId] > 1 ? `${op.name} ×${item.options[op.componentId]}` : op.name);
            }));
            const notes = (site.ruleNotes || []).filter((m) => m.itemKey === item.key).map((m, n) => ({
                key: `${item.key}-r${n}`,
                text: m.message,
                cssClass: 'ms-rule' + (m.severity === 'error' ? ' ms-rule_error' : '')
            }));
            return {
                key: item.key,
                notes,
                name: item.quantity > 1 ? `${item.offer.name} ×${item.quantity}` : item.offer.name,
                options: optionNames.join(', '),
                monthly: formatMoney(e.monthly, this.currencyCode),
                oneTime: e.oneTime ? formatMoney(e.oneTime, this.currencyCode) : null,
                isBundle: item.offer.isBundle
            };
        });
    }
    get siteCartEmpty() {
        return !this.selectedSite || this.selectedSite.cart.length === 0;
    }
    get siteTotals() {
        const t = this.selectedSite ? this.cartTotals(this.selectedSite) : { monthly: 0, oneTime: 0 };
        return { monthly: formatMoney(t.monthly, this.currencyCode), oneTime: formatMoney(t.oneTime, this.currencyCode) };
    }
    get canApplyToAll() {
        return !this.siteCartEmpty && this.buildSites.length > 1;
    }
    get reviewDisabled() {
        return this.busy || !this.sites.some((s) => s.status === 'ok' && s.cart.length);
    }
    get sitesWithPlansLabel() {
        const n = this.sites.filter((s) => s.status === 'ok' && s.cart.length).length;
        return `${n} of ${this.buildSites.length} site(s) have plans`;
    }

    handlePickSite(event) {
        this.selectedKey = event.currentTarget.dataset.key;
        this.configuring = undefined;
    }

    handleSelectOffer(event) {
        const site = this.selectedSite;
        const offer = site.categories.flatMap((c) => c.offers).find((o) => o.productId === event.detail.productId);
        if (!offer) return;
        const pricedOffer = this.withStatePrices(offer, site.address.state);
        if (offer.isBundle) {
            this.configuring = { offer: pricedOffer, selections: defaultSelections(offer), key: null };
            this.revealConfigurator();
            return;
        }
        const existing = site.cart.find((i) => i.offer.productId === offer.productId);
        const cart = existing
            ? site.cart.map((i) => (i === existing ? { ...i, quantity: Math.min(5, i.quantity + 1) } : i))
            : [...site.cart, { key: nextKey('item'), offer: pricedOffer, quantity: 1, options: {} }];
        this.patchSites([site.key], { cart });
        this.checkRules([site.key]);
    }

    handleConfigConfirm(event) {
        const site = this.selectedSite;
        const { offer, key } = this.configuring;
        const selections = event.detail.selections;
        const cart = key
            ? site.cart.map((i) => (i.key === key ? { ...i, options: selections } : i))
            : [...site.cart, { key: nextKey('item'), offer, quantity: 1, options: selections }];
        this.patchSites([site.key], { cart });
        this.configuring = undefined;
        this.checkRules([site.key]);
    }

    handleConfigCancel() {
        this.configuring = undefined;
    }

    handleEditItem(event) {
        const item = this.selectedSite.cart.find((i) => i.key === event.currentTarget.dataset.key);
        if (item) {
            this.configuring = { offer: item.offer, selections: { ...item.options }, key: item.key };
            this.revealConfigurator();
        }
    }

    handleRemoveItem(event) {
        const site = this.selectedSite;
        this.patchSites([site.key], { cart: site.cart.filter((i) => i.key !== event.currentTarget.dataset.key) });
        this.checkRules([site.key]);
    }

    /** Copies this site's cart to every other checked site that offers the same plans, at that site's state prices. */
    handleApplyToAll() {
        const source = this.selectedSite;
        let applied = 0;
        const skipped = [];
        this.sites = this.sites.map((s) => {
            if (s.key === source.key || s.status !== 'ok') return s;
            const offers = s.categories.flatMap((c) => c.offers);
            const cart = [];
            const missing = [];
            source.cart.forEach((item) => {
                const offer = offers.find((o) => o.productId === item.offer.productId);
                const optionIds = new Set((offer?.groups || []).flatMap((g) => g.options.map((op) => op.componentId)));
                const optionsOk = offer && Object.keys(item.options).every((id) => !item.options[id] || optionIds.has(id));
                if (optionsOk) {
                    cart.push({ key: nextKey('item'), offer: this.withStatePrices(offer, s.address.state), quantity: item.quantity,
                        options: { ...item.options } });
                } else {
                    missing.push(item.offer.name);
                }
            });
            if (missing.length) skipped.push(`${s.name} (no ${[...new Set(missing)].join(', ')})`);
            if (!cart.length) return s;
            applied++;
            return { ...s, cart };
        });
        this.notice = `${source.name}'s plans copied to ${applied} site(s), priced for each site's state`
            + (skipped.length ? `. Not available at: ${skipped.join('; ')}.` : '.');
        this.checkRules(this.sites.filter((s) => s.key !== source.key && s.status === 'ok' && s.cart.length).map((s) => s.key));
    }

    // ── Configuration rules (CML) ────────────────────────────────────────────

    /**
     * Runs the sites' carts through the Revenue Cloud configurator in the background, so the configuration rules
     * (CML: NF_Business_Rules) can add, remove or hide options right away; the cart follows what they leave.
     */
    async checkRules(keys) {
        const carts = this.siteCarts().filter((c) => keys.includes(c.key));
        const empty = keys.filter((k) => !carts.some((c) => c.key === k));
        if (empty.length) this.patchSites(empty, { ruleNotes: [], ruleHidden: {} });
        if (!carts.length) return;
        const seq = (this.ruleSeq = (this.ruleSeq || 0) + 1);
        this.patchSites(carts.map((c) => c.key), { checkingRules: true });
        try {
            const summaries = await nfApi.priceSiteCarts(carts);
            if (seq === this.ruleSeq) summaries.forEach((sum) => this.applyRules(sum));
        } catch (e) {
            // the review prices every site again and shows any error
        } finally {
            if (seq === this.ruleSeq) this.patchSites(carts.map((c) => c.key), { checkingRules: false });
        }
    }

    applyRules(sum) {
        const site = this.sites.find((s) => s.key === sum.key);
        if (!site) return;
        const byItem = new Map((sum.ruleAdjustments || []).map((a) => [a.itemKey, a]));
        const cart = site.cart.map((i) => {
            const a = byItem.get(i.key);
            return a ? { ...i, options: Object.fromEntries((a.options || []).map((o) => [o.componentId, o.quantity])) } : i;
        });
        const ruleHidden = {};
        (sum.hiddenOptions || []).forEach((h) => {
            ruleHidden[h.itemKey] = { ...(ruleHidden[h.itemKey] || {}), [h.componentId]: h.treatment };
        });
        const ruleNotes = (sum.messages || []).filter((m) => m.category === 'cml' || m.category === 'configurationrules'
            || m.severity === 'error');
        this.patchSites([site.key], { cart, ruleNotes, ruleHidden });
    }

    get configuringRuleHidden() {
        const key = this.configuring?.key;
        return (key && this.selectedSite?.ruleHidden?.[key]) || {};
    }
    get checkingRules() {
        return !!this.selectedSite?.checkingRules;
    }

    handleBackToSites() {
        this.step = 'sites';
        this.configuring = undefined;
    }

    /** Prices every site's cart for its state in Revenue Cloud (one configure call, nothing saved). */
    async handleReview() {
        this.error = undefined;
        this.notice = undefined;
        this.busy = true;
        this.busyMessage = 'Pricing every site with Revenue Cloud';
        try {
            this.priced = await nfApi.priceSiteCarts(this.siteCarts());
            this.priced.forEach((sum) => this.applyRules(sum));
            this.step = 'review';
            this.scrollTop();
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.busy = false;
        }
    }

    siteCarts() {
        return this.sites.filter((s) => s.status === 'ok' && s.cart.length).map((s) => ({
            key: s.key,
            name: s.name,
            serviceability: s.serviceability,
            items: s.cart.map((item) => ({
                key: item.key,
                productId: item.offer.productId,
                quantity: item.quantity,
                discountPercent: null,
                options: Object.keys(item.options).filter((id) => item.options[id] > 0)
                    .map((id) => ({ componentId: id, quantity: item.options[id] }))
            }))
        }));
    }

    // ── Step 3: review & create the quote ────────────────────────────────────

    summaryView(sites) {
        return (sites || []).map((s) => {
            const parents = s.lines.filter((l) => !l.parentLineId);
            return {
                key: s.key,
                name: s.name,
                state: s.state,
                monthly: formatMoney(s.monthlyTotal, this.currencyCode),
                oneTime: formatMoney(s.oneTimeTotal, this.currencyCode),
                hasMessages: (s.messages || []).length > 0,
                messages: (s.messages || []).map((m, i) => ({ key: `${s.key}-m${i}`, text: m.message,
                    cssClass: (m.category === 'cml' || m.category === 'configurationrules') && m.severity !== 'error'
                        ? 'ms-rule' : 'nf-msg nf-msg_' + (m.severity || 'info') })),
                lines: parents.map((p) => ({
                    key: p.lineId,
                    name: p.productName,
                    price: formatMoney(p.listPrice, this.currencyCode),
                    net: formatMoney(p.netTotal, this.currencyCode),
                    unit: p.chargeType === 'One-Time' ? '' : '/mo',
                    children: s.lines.filter((c) => c.parentLineId === p.lineId).map((c) => ({
                        key: c.lineId,
                        name: c.productName,
                        net: formatMoney(c.netTotal, this.currencyCode),
                        unit: c.chargeType === 'One-Time' ? ' one-time' : '/mo'
                    }))
                }))
            };
        });
    }
    get reviewSites() {
        return this.summaryView(this.priced);
    }
    get reviewTotals() {
        const t = (this.priced || []).reduce((a, s) => ({ monthly: a.monthly + (s.monthlyTotal || 0), oneTime: a.oneTime + (s.oneTimeTotal || 0) }),
            { monthly: 0, oneTime: 0 });
        return { monthly: formatMoney(t.monthly, this.currencyCode), oneTime: formatMoney(t.oneTime, this.currencyCode) };
    }
    get reviewHasErrors() {
        return (this.priced || []).some((s) => s.hasErrors);
    }
    get hasAccount() {
        return !!this.account?.accountId;
    }
    get busyProgress() {
        return progressFor(this.busyMessage);
    }
    get companyLabel() {
        return this.isAgent ? 'Business name (new customer account)' : 'Your business name';
    }
    get orderIntro() {
        return this.isAgent
            ? 'The customer contact is the bill-to and authorising contact. The order is activated and sent to fulfillment.'
            : 'You are the bill-to and authorising contact. Set a password to follow every site\'s installation in My NovaFiber.';
    }
    get createDisabled() {
        return this.busy || this.reviewHasErrors || (!this.hasAccount && !this.companyName.trim());
    }

    handleCompany(event) {
        this.companyName = event.detail.value || '';
    }

    handleBackToBuild() {
        this.step = 'build';
    }

    async handleCreateQuote() {
        this.error = undefined;
        this.busy = true;
        this.busyMessage = 'Creating the quote: a service location and line group per site, priced by state';
        try {
            this.quote = await nfApi.saveMultiSiteQuote({
                accountId: this.account?.accountId || null,
                companyName: this.hasAccount ? null : this.companyName.trim(),
                sites: this.siteCarts()
            });
            this.step = 'done';
            this.scrollTop();
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.busy = false;
        }
    }

    // ── Step 4: done ─────────────────────────────────────────────────────────

    get doneSites() {
        return this.summaryView(this.quote?.sites);
    }
    get doneTotals() {
        return {
            monthly: formatMoney(this.quote?.monthlyTotal, this.currencyCode),
            oneTime: formatMoney(this.quote?.oneTimeTotal, this.currencyCode)
        };
    }

    handleOpenQuote() {
        this.dispatchEvent(new CustomEvent('openrecord', { detail: { recordId: this.quote.quoteId, objectApiName: 'Quote' } }));
    }

    get hasOrder() {
        return !!this.order;
    }
    get minInstallDate() {
        const d = new Date();
        d.setDate(d.getDate() + 1);
        return d.toISOString().slice(0, 10);
    }
    get orderDisabled() {
        const c = this.contact;
        const missing = !c.firstName.trim() || !c.lastName.trim() || !c.email.trim() || !c.phone.trim();
        const guestMissing = !this.isAgent && (!c.portalPassword || !this.confirmPassword || !this.acceptedTerms);
        return this.busy || missing || guestMissing;
    }
    get isGuest() {
        return !this.isAgent;
    }
    get canTrack() {
        return !this.isAgent && !!this.order?.portalUsername;
    }
    get orderStatusLabel() {
        return this.order?.submittedToFulfillment
            ? 'Activated and submitted to fulfillment: every site gets its own installation, circuit and service steps.'
            : 'Created, but not yet with fulfillment. Operations will pick it up.';
    }

    handleContact(event) {
        this.contact = { ...this.contact, [event.target.name]: event.detail.value };
        if (['firstName', 'lastName', 'email'].includes(event.target.name) && !this.proposalSigned) {
            this.showProposal = false;   // a different signer needs a new proposal
        }
    }

    /** The proposal (native quote document, context definition) is generated and sent for signature first. */
    handlePrepareProposal() {
        if (!this.passwordValid()) return;
        const { portalPassword, ...signer } = this.contact; // eslint-disable-line no-unused-vars
        this.proposalSigner = { ...signer, isBusiness: true };
        this.showProposal = false;
        // re-render the component for a fresh generation
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => {
            this.showProposal = true;
        });
    }
    handleProposalSigned() {
        this.proposalSigned = true;
    }
    handleConfirm(event) {
        this.confirmPassword = event.detail.value;
    }
    handleTerms(event) {
        this.acceptedTerms = event.detail.checked;
    }

    /** Same rules as NF_PortalService.checkPasswordRules (and nfCheckoutForm). */
    passwordValid() {
        const pw = this.template.querySelector('lightning-input[name="portalPassword"]');
        const confirm = this.template.querySelector('lightning-input[name="confirmPassword"]');
        if (!pw || !confirm) return true;
        const value = this.contact.portalPassword || '';
        pw.setCustomValidity(value.length >= 10 && /[A-Za-z]/.test(value) && /[0-9]/.test(value)
            ? '' : 'Use at least 10 characters with letters and numbers');
        confirm.setCustomValidity(value === this.confirmPassword ? '' : 'The passwords don\'t match');
        return [pw, confirm].reduce((ok, el) => el.reportValidity() && ok, true);
    }

    /** Quote → order (Revenue Cloud), activation and submission to Dynamic Revenue Orchestrator. */
    async handlePlaceOrder() {
        this.error = undefined;
        if (!this.passwordValid()) return;
        this.busy = true;
        this.busyMessage = 'Creating the order and submitting it to fulfillment';
        try {
            const customer = { ...this.contact, acceptedTerms: this.isAgent || this.acceptedTerms };
            if (this.isAgent) delete customer.portalPassword;
            this.order = await nfApi.submitOrder(this.quote.quoteId, customer);
            this.contact = { ...this.contact, portalPassword: '' };
            this.confirmPassword = '';
            this.loadInstallSites();
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.busy = false;
        }
    }

    /** Field Service: the order's sites and any appointments already booked. */
    async loadInstallSites() {
        try {
            this.installSites = await nfApi.installSites(this.order.orderId, this.order.bookingToken);
        } catch (e) {
            this.error = reduceError(e);
        }
    }
    get installProgress() {
        const booked = this.installSites.filter((s) => s.appointment?.appointmentId).length;
        return `${booked} of ${this.installSites.length} sites booked`;
    }
    handleInstallBooked(event) {
        const { siteKey, appointment } = event.detail;
        this.installSites = this.installSites.map((s) => (s.siteKey === siteKey ? { ...s, appointment } : s));
    }

    handleTrack() {
        this.dispatchEvent(new CustomEvent('track', { detail: { username: this.order.portalUsername } }));
    }

    handleOpenOrder() {
        this.dispatchEvent(new CustomEvent('openrecord', { detail: { recordId: this.order.orderId, objectApiName: 'Order' } }));
    }

    handleStartOver() {
        this.step = 'sites';
        this.sites = [];
        this.selectedKey = undefined;
        this.priced = undefined;
        this.quote = undefined;
        this.order = undefined;
        this.contact = { firstName: '', lastName: '', email: '', phone: '', preferredInstallDate: null, portalPassword: '' };
        this.confirmPassword = '';
        this.acceptedTerms = false;
        this.installSites = [];
        this.showProposal = false;
        this.proposalSigned = false;
        this.proposalSigner = undefined;
        this.companyName = '';
        this.notice = undefined;
        this.error = undefined;
    }

    // ── Misc ─────────────────────────────────────────────────────────────────

    dismissError() {
        this.error = undefined;
    }
    dismissNotice() {
        this.notice = undefined;
    }
    /** Brings the configurator (rendered under the chosen plan's row) into view once it has rendered. */
    revealConfigurator() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() =>
            this.template.querySelector('.ms-config-inline')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }));
    }
    scrollTop() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => this.template.querySelector('.ms')?.scrollIntoView({ block: 'start', behavior: 'smooth' }));
    }
}
