import { LightningElement, api } from 'lwc';
import { subscribe, clearLog } from 'c/nfApi';

const KIND_STYLE = {
    APEX: 'k-apex',
    CALLOUT: 'k-callout',
    SOQL: 'k-soql',
    DML: 'k-dml',
    PST: 'k-pst',
    FLOW: 'k-flow',
    EVENT: 'k-event',
    WORKER: 'k-worker',
    RULE: 'k-rule',
    RC_API: 'k-rcapi',
    CACHE: 'k-cache',
    AGENT_API: 'k-agent',
    AGENT_ACTION: 'k-action'
};
const FILTERS = [
    { key: 'ALL', label: 'All' },
    { key: 'APEX', label: 'Apex' },
    { key: 'AI', label: 'Agentforce' },
    { key: 'CALLOUT', label: 'Callout' },
    { key: 'RC', label: 'Revenue Cloud' },
    { key: 'DATA', label: 'SOQL / DML' }
];
const MAX_JSON = 8000;

/** Sequence diagram participants, left to right; only the ones a call touched are drawn. */
const LANES = [
    { key: 'browser', label: 'Browser', sub: 'LWC · nfApi' },
    { key: 'apex', label: 'Apex', sub: 'Journey controller · gateway' },
    { key: 'agent', label: 'Agentforce', sub: 'Agent API · Nova' },
    { key: 'action', label: 'Agent actions', sub: 'Apex · agent user' },
    { key: 'cache', label: 'Org cache', sub: 'Platform Cache' },
    { key: 'mock', label: 'Network API', sub: 'Serviceability mock' },
    { key: 'rc', label: 'Revenue Cloud', sub: 'Connect REST APIs' },
    { key: 'worker', label: 'Worker', sub: 'Platform event' },
    { key: 'db', label: 'Database', sub: 'SOQL / DML' }
];
const LANE_W = 168;
const ROW_H = 30;
const SEP_H = 30;
const HEAD_H = 52;
const CHAR_W = 6.1;

function clip(text, px) {
    const max = Math.max(10, Math.floor(px / CHAR_W));
    return text && text.length > max ? text.slice(0, max - 1) + '…' : text || '';
}

/** Short name of a cache lookup for the sequence diagram. */
function cacheLabel(t) {
    const label = t.label || '';
    if (label.startsWith('Serviceability verified')) return 'address check ✓ (server copy)';
    if (label.startsWith('Serviceability from cache')) return 'serviceability ✓';
    if (label.startsWith('Offers')) return 'offers ✓';
    if (label.startsWith('Catalog preview')) return 'catalog ✓';
    if (label.startsWith('Priced cart')) return 'priced cart ✓';
    return label;
}

/** Short label for a Revenue Cloud call: the API family plus what it did. */
function rcLabel(t) {
    const path = (t.label || '').replace(/^(GET|POST|PATCH|DELETE) /, '');
    let api = path;
    if (path.includes('/configurator/')) api = 'Configurator';
    else if (path.includes('/cpq/products')) api = 'Product Discovery';
    else if (path.includes('/sales-transaction/')) api = 'Place Sales Transaction';
    else if (path.includes('/sobjects/')) api = 'sObject ' + path.split('/sobjects/')[1];
    else if (t.kind === 'FLOW') api = t.label;
    const what = (t.detail || '').replace(/^(Product Discovery|Product details|Configurator|Place Sales Transaction) · /, '');
    return what ? `${api} · ${what}` : api;
}

/**
 * Who built a trace step: NovaFiber code and configuration (custom), Salesforce out of the box (ootb) or an outside
 * system (external). Returns { origin, component, what } for the Behind-the-scenes view.
 */
function classify(t) {
    const label = t.label || '';
    const detail = t.detail || '';
    const path = label.replace(/^(GET|POST|PATCH|PUT|DELETE) /, '');
    switch (t.kind) {
        case 'APEX':
            return { origin: 'custom', component: 'Apex · ' + label.split(' ')[0], what: detail };
        case 'AGENT_ACTION':
            return { origin: 'custom', component: 'Agent action · ' + label, what: 'Apex invocable, runs as the agent user' };
        case 'AGENT_API':
            return { origin: 'ootb', component: 'Agentforce · Agent API', what: detail.replace(/^Agentforce · /, '') || path };
        case 'PST':
            return { origin: 'ootb', component: 'Revenue Cloud · Place Sales Transaction', what: detail };
        case 'FLOW':
            return { origin: /^NF/.test(label) ? 'custom' : 'ootb', component: 'Flow · ' + label, what: detail };
        case 'RC_API': {
            let component = 'Salesforce REST API';
            if (path.includes('/configurator/')) component = 'Revenue Cloud · Configurator API';
            else if (path.includes('/cpq/products')) component = 'Revenue Cloud · Product Discovery API';
            else if (path.includes('/sales-transaction/')) component = 'Revenue Cloud · Place Sales Transaction';
            else if (path.includes('/e-sign/')) component = 'Salesforce Contracts · e-signature';
            else if (path.includes('/actions/standard/')) component = 'Invocable action · ' + path.split('/actions/standard/')[1].split(/[/?]/)[0];
            else if (path.includes('/sobjects/')) component = 'REST API · ' + path.split('/sobjects/')[1].split('/')[0];
            else if (path.includes('/composite')) component = 'REST API · composite';
            else if (path.includes('/query')) component = 'REST API · query';
            return { origin: 'ootb', component, what: detail };
        }
        case 'RULE':
            if (label.startsWith('Configuration rules (CML)')) {
                return { origin: 'custom', component: 'CML rules · NovaFiber models', what: 'run by the Revenue Cloud constraint engine · ' + detail };
            }
            if (label.startsWith('Configurator rules') || label.startsWith('Revenue Cloud qualification')) {
                return { origin: 'ootb', component: 'Revenue Cloud · ' + label, what: detail };
            }
            return { origin: 'custom', component: 'Journey rule · ' + label, what: detail };
        case 'CALLOUT':
            return { origin: 'external', component: label.includes('NF_Serviceability') ? 'Network inventory API (mock)' : 'External system (mock)', what: detail || path };
        case 'ESIGN':
            if (label.startsWith('Sandbox') || label.startsWith('Signed PDF')) return { origin: 'custom', component: 'E-signature · ' + label, what: detail };
            return { origin: 'external', component: 'DocuSign eSignature API', what: detail || path };
        case 'FSL':
            return { origin: 'ootb', component: 'Field Service', what: (label + ' ' + detail).trim() };
        case 'CACHE':
            return { origin: 'ootb', component: 'Platform Cache', what: label };
        case 'EVENT':
        case 'WORKER':
            return { origin: 'custom', component: (t.kind === 'EVENT' ? 'Platform event · ' : 'Worker · ') + label, what: detail };
        default:
            return { origin: 'ootb', component: t.kind, what: label };
    }
}

/** The custom Lightning Web Component behind each page call (all go through c/nfApi). */
const UI_OF = {
    getCatalogPreview: 'nfGuidedSelling · home',
    checkServiceability: 'nfGuidedSelling · address',
    overrideServiceability: 'nfGuidedSelling · agent override',
    getOffers: 'nfGuidedSelling · plans',
    startCart: 'nfGuidedSelling · cart session',
    syncCart: 'nfGuidedSelling · nfCart',
    priceCart: 'nfGuidedSelling · nfQuoteReview',
    discardJourney: 'nfGuidedSelling',
    flushJourneyCache: 'nfGuidedSelling · agent bar',
    getRequestResult: 'nfGuidedSelling',
    submitOrder: 'nfCheckoutForm · order',
    prepareAgreement: 'nfAgreement',
    getAgreement: 'nfAgreement',
    startSigning: 'nfAgreement · DocuSign',
    completeSigning: 'nfAgreement · DocuSign',
    getInstallSites: 'nfInstallBooking',
    getInstallSlots: 'nfInstallBooking · calendar',
    bookInstall: 'nfInstallBooking',
    startChat: 'nfAgentJourney · Nova chat',
    sendMessage: 'nfAgentJourney · Nova chat',
    saveCustomer: 'nfAgentJourney · secure form',
    endChat: 'nfAgentJourney · Nova chat',
    searchAccounts: 'nfAgentPanel',
    checkSites: 'nfMultiSite · sites',
    getStatePrices: 'nfMultiSite · state prices',
    priceSiteCarts: 'nfMultiSite · site carts',
    saveMultiSiteQuote: 'nfMultiSite · quote',
    login: 'nfPortal',
    logout: 'nfPortal',
    getDashboard: 'nfPortal'
};

/** Method and endpoint of a step that is an API call, to show it highlighted. */
function endpointOf(t) {
    const label = (t.label || '').trim();
    if (['RC_API', 'AGENT_API', 'ESIGN', 'CALLOUT'].includes(t.kind) && /^(GET|POST|PATCH|PUT|DELETE) /.test(label)) {
        return label.replace(/\?.*$/, '');
    }
    return null;
}

const ORIGINS = {
    custom: { label: 'Custom', hint: 'NovaFiber code and configuration' },
    ootb: { label: 'Salesforce', hint: 'out of the box' },
    external: { label: 'External', hint: 'outside systems' }
};

function pretty(value) {
    if (value === null || value === undefined || value === '') {
        return null;
    }
    let text;
    if (typeof value === 'string') {
        try {
            text = JSON.stringify(JSON.parse(value), null, 2);
        } catch (e) {
            text = value;
        }
    } else {
        text = JSON.stringify(value, null, 2);
    }
    return text.length > MAX_JSON ? text.slice(0, MAX_JSON) + '\n… (truncated)' : text;
}

function time(ms) {
    const d = new Date(ms);
    const pad = (n, l = 2) => String(n).padStart(l, '0');
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

/**
 * Journey Inspector: the calls the journey made (client round trip + server trace tree),
 * the records stored and retrieved, and the current journey context.
 */
export default class NfInspector extends LightningElement {
    /** { channel, isAgent, isGuest } from NF_JourneyController.getContext */
    @api context;
    /** Snapshot of the journey state for the Context tab. */
    @api journeyState;

    tab = 'bts';
    filter = 'ALL';
    entries = [];
    expanded = {};
    copiedId;
    unsubscribe;

    connectedCallback() {
        this.unsubscribe = subscribe((log) => {
            this.entries = log;
            // Auto-expand the newest call so the latest activity is visible.
            if (log.length) {
                this.expanded = { ...this.expanded, [log[log.length - 1].id]: true };
            }
        });
    }
    disconnectedCallback() {
        if (this.unsubscribe) {
            this.unsubscribe();
        }
    }

    // ── Header ───────────────────────────────────────────────────────────────

    get channelLabel() {
        if (!this.context) {
            return '';
        }
        return `${this.context.channel}${this.context.isGuest ? ' · Guest' : ''}`;
    }
    get tabs() {
        return [
            { key: 'bts', label: 'Behind the scenes' },
            { key: 'calls', label: `Calls · ${this.entries.length}` },
            { key: 'flow', label: 'Sequence' },
            { key: 'data', label: `Data · ${this.allRecords.length}` },
            { key: 'context', label: 'Context' }
        ].map((t) => ({
            ...t,
            selected: t.key === this.tab,
            cssClass: 'nf-tab' + (t.key === this.tab ? ' nf-tab_on' : '')
        }));
    }
    get filters() {
        return FILTERS.map((f) => ({ ...f, cssClass: 'nf-filter' + (f.key === this.filter ? ' nf-filter_on' : '') }));
    }
    get isCalls() {
        return this.tab === 'calls';
    }
    get isBts() {
        return this.tab === 'bts';
    }
    get isData() {
        return this.tab === 'data';
    }
    get isFlow() {
        return this.tab === 'flow';
    }
    get isContext() {
        return this.tab === 'context';
    }
    get totals() {
        return this.entries.reduce(
            (acc, e) => {
                acc.calls += e.count || 1;
                acc.callouts += e.trace.filter((t) => t.kind === 'CALLOUT').length;
                acc.pst += e.trace.filter((t) => t.kind === 'PST').length;
                acc.records += e.trace.reduce((n, t) => n + (t.records ? t.records.length : 0), 0);
                acc.ms += e.clientMs || 0;
                return acc;
            },
            { calls: 0, callouts: 0, pst: 0, records: 0, ms: 0 }
        );
    }

    // ── Calls ────────────────────────────────────────────────────────────────

    matches(step) {
        switch (this.filter) {
            case 'APEX':
                return step.kind === 'APEX' || step.kind === 'RULE';
            case 'AI':
                return step.kind === 'AGENT_API' || step.kind === 'AGENT_ACTION';
            case 'CALLOUT':
                return step.kind === 'CALLOUT';
            case 'RC':
                return ['RC_API', 'PST', 'FLOW', 'WORKER', 'EVENT', 'CACHE'].includes(step.kind);
            case 'DATA':
                return step.kind === 'SOQL' || step.kind === 'DML';
            default:
                return true;
        }
    }

    get calls() {
        return [...this.entries]
            .reverse()
            .map((e) => {
                const depthOf = {};
                const steps = e.trace
                    .map((t) => {
                        const depth = t.parentId && depthOf[t.parentId] !== undefined ? depthOf[t.parentId] + 1 : 0;
                        depthOf[t.id] = depth;
                        const key = `${e.id}:${t.id}`;
                        const open = !!this.expanded[key];
                        const req = open ? pretty(t.requestJson) : null;
                        const res = open ? pretty(t.responseJson) : null;
                        return {
                            key,
                            kind: t.kind,
                            label: t.label,
                            detail: t.detail,
                            badgeClass: 'nf-badge ' + (KIND_STYLE[t.kind] || 'k-apex'),
                            statusClass: t.status === 'OK' ? 'nf-ok' : 'nf-err',
                            duration: t.durationMs !== undefined && t.durationMs !== null ? `${t.durationMs} ms` : '',
                            style: `padding-left: ${depth * 14}px`,
                            hasBody: !!(t.requestJson || t.responseJson || (t.records && t.records.length)),
                            open,
                            toggleLabel: open ? 'Hide' : 'Show',
                            request: req,
                            response: res,
                            records: (t.records || []).map((r, i) => ({ ...r, key: `${key}:${i}` })),
                            hasRecords: open && t.records && t.records.length > 0
                        };
                    })
                    .filter((s) => this.matches(s));
                const open = !!this.expanded[e.id];
                const errorish = e.status !== 'OK';
                return {
                    id: e.id,
                    name: e.count > 1 ? `${e.name}() ×${e.count}` : `${e.name}()`,
                    at: time(e.at),
                    timing: `${e.clientMs} ms` + (e.serverMs !== undefined && e.serverMs !== null ? ` · server ${e.serverMs} ms` : ''),
                    statusLabel: errorish ? 'Error' : e.response && e.response.status === 'Pending' ? 'Pending' : 'OK',
                    statusClass: errorish ? 'nf-err' : 'nf-ok',
                    cardClass: 'nf-call' + (open ? ' nf-call_open' : '') + (errorish ? ' nf-call_err' : ''),
                    open,
                    error: e.error,
                    params: open ? pretty(e.params) : null,
                    response: open ? pretty(e.response) : null,
                    limits: e.limits
                        ? `SOQL ${e.limits.soql} · DML ${e.limits.dml} · callouts ${e.limits.callouts} · CPU ${e.limits.cpuMs} ms`
                        : null,
                    steps,
                    hasSteps: steps.length > 0
                };
            })
            .filter((c) => this.filter === 'ALL' || c.hasSteps);
    }
    get hasCalls() {
        return this.entries.length > 0;
    }


    // ── Behind the scenes ────────────────────────────────────────────────────

    /** Every step of every call, split by who built it: custom, Salesforce out of the box, external. */
    get btsTotals() {
        const n = { custom: 0, ootb: 0, external: 0 };
        this.entries.forEach((e) => {
            n.custom += 1; // the page's LWC → Apex call
            let cache = false;
            e.trace.forEach((t) => {
                if (t.kind === 'CACHE') {
                    cache = true;
                    return;
                }
                if (t.kind !== 'SOQL' && t.kind !== 'DML' && !(t.kind === 'APEX' && !t.parentId)) n[classify(t).origin] += 1;
            });
            if (cache) n.ootb += 1;
        });
        return Object.keys(ORIGINS).map((k) => ({
            key: k,
            count: n[k],
            label: ORIGINS[k].label,
            hint: ORIGINS[k].hint,
            cssClass: 'bt-tile bt-' + k
        }));
    }

    /** The latest calls, newest first: the page's call, then what ran behind it, labelled custom / Salesforce / external. */
    get btsCalls() {
        return [...this.entries]
            .reverse()
            .slice(0, 12)
            .map((e, idx) => {
                const rows = [];
                let reads = 0;
                let writes = 0;
                let cacheRow;
                e.trace.forEach((t, i) => {
                    if (t.kind === 'CACHE') {
                        // One row per call for every cache hit: they are 0 ms lookups, not separate work.
                        const what = cacheLabel(t);
                        if (cacheRow) {
                            if (!cacheRow.parts.includes(what)) cacheRow.parts.push(what);
                        } else {
                            cacheRow = { key: `${e.id}:cache`, component: 'Platform Cache', parts: [what], hasWhat: true,
                                tag: ORIGINS.ootb.label, tagClass: 'bt-tag bt-ootb', rowClass: 'bt-row bt-row_ootb', duration: '0 ms' };
                            rows.push(cacheRow);
                        }
                        return;
                    }
                    if (t.kind === 'SOQL') {
                        reads += 1;
                        return;
                    }
                    if (t.kind === 'DML') {
                        writes += 1;
                        return;
                    }
                    if (t.kind === 'APEX' && !t.parentId) return; // the call itself is the header
                    const c = classify(t);
                    const endpoint = endpointOf(t);
                    rows.push({
                        key: `${e.id}:${i}`,
                        endpoint,
                        hasEndpoint: !!endpoint,
                        apiClass: 'bt-api bt-api_' + c.origin,
                        component: c.component,
                        what: c.what,
                        hasWhat: !!c.what,
                        tag: ORIGINS[c.origin].label,
                        tagClass: 'bt-tag bt-' + c.origin,
                        rowClass: 'bt-row bt-row_' + c.origin,
                        duration: t.durationMs !== undefined && t.durationMs !== null ? `${t.durationMs} ms` : ''
                    });
                });
                if (cacheRow) cacheRow.what = 'read · ' + cacheRow.parts.join(' · ');
                if (reads || writes) {
                    rows.push({
                        key: `${e.id}:data`,
                        component: 'Salesforce data',
                        what: [reads ? `${reads} quer${reads === 1 ? 'y' : 'ies'}` : '', writes ? `${writes} write${writes === 1 ? '' : 's'}` : '']
                            .filter(Boolean).join(' · '),
                        hasWhat: true,
                        tag: ORIGINS.ootb.label,
                        tagClass: 'bt-tag bt-ootb',
                        rowClass: 'bt-row bt-row_ootb',
                        duration: ''
                    });
                }
                const root = e.trace.find((t) => t.kind === 'APEX' && !t.parentId);
                return {
                    id: e.id,
                    cardClass: 'bt-call' + (idx === 0 ? ' bt-call_latest' : '') + (e.status !== 'OK' ? ' bt-call_err' : ''),
                    entry: (root ? root.label.split(' ')[0] : e.name) + '()',
                    ui: UI_OF[e.name] || 'nfGuidedSelling',
                    timing: `${e.clientMs} ms`,
                    rows,
                    hasRows: rows.length > 0
                };
            });
    }

    // ── Sequence diagram ─────────────────────────────────────────────────────

    /** Messages in time order: browser → Apex → systems, built from each call's server trace. */
    get sequenceMessages() {
        const msgs = [];
        this.entries.forEach((e) => {
            msgs.push({ sep: true, label: `${time(e.at)}  ${e.name}()${e.count > 1 ? ' ×' + e.count : ''}`, callId: e.id });
            msgs.push({ from: 'browser', to: 'apex', label: `${e.name}()`, kind: 'client', callId: e.id });
            const byId = {};
            e.trace.forEach((t) => {
                byId[t.id] = t;
            });
            const actorOf = (t) => {
                let p = t.parentId ? byId[t.parentId] : null;
                while (p) {
                    if (p.kind === 'WORKER') {
                        return 'worker';
                    }
                    if (p.kind === 'AGENT_ACTION') {
                        return 'action';
                    }
                    p = p.parentId ? byId[p.parentId] : null;
                }
                return 'apex';
            };
            const isUnder = (t, ancestorId) => {
                let p = t.parentId ? byId[t.parentId] : null;
                while (p) {
                    if (p.id === ancestorId) {
                        return true;
                    }
                    p = p.parentId ? byId[p.parentId] : null;
                }
                return false;
            };
            // Cache lookups take ~0 ms: consecutive ones are drawn as one short arrow, not one call each.
            let cacheHits = [];
            let cacheFrom = 'apex';
            const flushCache = () => {
                if (cacheHits.length) {
                    msgs.push({ from: cacheFrom, to: 'cache', label: `cache · ${cacheHits.join(' · ')}`, kind: 'cache', callId: e.id });
                    cacheHits = [];
                }
            };
            // Agent API turns and agent actions answer after everything nested in them (the actions' own calls).
            const spans = [];
            const closeSpans = (t) => {
                while (spans.length && !(t && isUnder(t, spans[spans.length - 1].id))) {
                    flushCache();
                    const s = spans.pop();
                    msgs.push({ from: s.lane, to: s.caller, label: s.label, dashed: true, err: s.err, callId: e.id });
                }
            };
            e.trace.forEach((t) => {
                closeSpans(t);
                const from = actorOf(t);
                if (t.kind === 'CACHE') {
                    cacheFrom = from;
                    cacheHits.push(cacheLabel(t));
                    return;
                }
                if (t.kind !== 'RULE') {
                    flushCache();
                }
                const dur = t.durationMs !== undefined && t.durationMs !== null ? `${t.durationMs} ms` : '';
                const err = !!t.status && t.status !== 'OK';
                const back = (lane) =>
                    msgs.push({ from: lane, to: from, label: `${err ? 'error' : 'ok'}${dur ? ' · ' + dur : ''}`, dashed: true, err, callId: e.id });
                switch (t.kind) {
                    case 'APEX':
                        if (t.parentId) {
                            msgs.push({ note: true, lane: from, label: t.label, callId: e.id });
                        }
                        break;
                    case 'CALLOUT':
                        msgs.push({ from, to: 'mock', label: `${(t.label || '').split(' ')[0]} ${t.detail || t.label}`, kind: 'callout', callId: e.id });
                        back('mock');
                        break;
                    case 'RC_API':
                    case 'PST':
                    case 'FLOW':
                        msgs.push({ from, to: 'rc', label: rcLabel(t), kind: 'rc', callId: e.id });
                        back('rc');
                        break;
                    case 'SOQL':
                    case 'DML':
                        msgs.push({ from, to: 'db', label: `${t.label}${dur ? ' · ' + dur : ''}`, kind: 'db', callId: e.id });
                        break;
                    case 'EVENT':
                        msgs.push({ from, to: 'worker', label: t.label, kind: 'event', callId: e.id });
                        break;
                    case 'WORKER':
                        msgs.push({ note: true, lane: 'worker', label: t.label, callId: e.id });
                        break;
                    case 'RULE':
                        msgs.push({ note: true, lane: from, label: t.detail ? `${t.label}: ${t.detail}` : t.label, callId: e.id });
                        break;
                    case 'AGENT_API':
                        msgs.push({ from, to: 'agent', label: (t.detail || t.label || '').replace(/^Agentforce · /, ''), kind: 'agent', callId: e.id });
                        spans.push({ id: t.id, lane: 'agent', caller: from, err, label: `${err ? 'error' : 'reply'}${dur ? ' · ' + dur : ''}` });
                        break;
                    case 'AGENT_ACTION':
                        msgs.push({ from: 'agent', to: 'action', label: `${t.label}()`, kind: 'action', callId: e.id });
                        spans.push({ id: t.id, lane: 'action', caller: 'agent', err, label: `${err ? 'failed' : 'result'}${dur ? ' · ' + dur : ''}` });
                        break;
                    default:
                        break;
                }
            });
            flushCache();
            closeSpans(null);
            const failed = e.status !== 'OK';
            const server = e.serverMs !== undefined && e.serverMs !== null ? ` (server ${e.serverMs})` : '';
            msgs.push({
                from: 'apex',
                to: 'browser',
                label: `${failed ? 'error' : e.response && e.response.status === 'Pending' ? 'queued' : 'ok'} · ${e.clientMs} ms${server}`,
                dashed: true,
                err: failed,
                callId: e.id
            });
        });
        return msgs;
    }

    get sequence() {
        const msgs = this.sequenceMessages;
        const used = new Set(['browser', 'apex']);
        msgs.forEach((m) => {
            if (m.from) {
                used.add(m.from);
                used.add(m.to);
            }
            if (m.lane) {
                used.add(m.lane);
            }
        });
        const lanes = LANES.filter((l) => used.has(l.key)).map((l, i) => ({ ...l, x: i * LANE_W + LANE_W / 2 }));
        const xOf = {};
        lanes.forEach((l) => {
            xOf[l.key] = l.x;
        });
        const width = lanes.length * LANE_W;
        let y = HEAD_H;
        const items = msgs.map((m, i) => {
            const key = `m${i}`;
            if (m.sep) {
                y += SEP_H;
                return { key, isSep: true, callId: m.callId, x2: width, y: y - 18, textY: y - 6, label: m.label };
            }
            y += ROW_H;
            if (m.note) {
                const x = xOf[m.lane];
                return {
                    key, isNote: true, callId: m.callId,
                    rectX: x - LANE_W / 2 + 6, rectY: y - 19, rectW: LANE_W - 12, x, textY: y - 4,
                    label: clip(m.label, LANE_W - 20), title: m.label
                };
            }
            const x1 = xOf[m.from];
            const x2 = xOf[m.to];
            const dir = x2 > x1 ? 1 : -1;
            const tipX = x2 - dir * 2;
            return {
                key, isArrow: true, callId: m.callId,
                x1, x2: tipX, y,
                head: `${tipX},${y} ${tipX - dir * 8},${y - 4} ${tipX - dir * 8},${y + 4}`,
                textX: (x1 + x2) / 2, textY: y - 6,
                label: clip(m.label, Math.abs(x2 - x1) - 12), title: m.label,
                lineClass: 'sq-line sq-' + (m.err ? 'err' : m.kind || 'reply') + (m.dashed ? ' sq-dashed' : ''),
                headClass: 'sq-head sq-' + (m.err ? 'err' : m.kind || 'reply'),
                textClass: 'sq-text' + (m.err ? ' sq-text-err' : m.dashed ? ' sq-text-reply' : '')
            };
        });
        const height = y + 24;
        return {
            width,
            height,
            viewBox: `0 0 ${width} ${height}`,
            lanes: lanes.map((l) => ({ ...l, rectX: l.x - LANE_W / 2 + 6, rectW: LANE_W - 12, lifeY2: height - 6 })),
            items
        };
    }
    get hasSequence() {
        return this.entries.length > 0;
    }

    handleSequenceClick(event) {
        const id = event.currentTarget.dataset.call;
        if (id) {
            this.tab = 'calls';
            this.filter = 'ALL';
            this.expanded = { ...this.expanded, [id]: true };
        }
    }

    // ── Data ─────────────────────────────────────────────────────────────────

    get allRecords() {
        const out = [];
        this.entries.forEach((e) =>
            e.trace.forEach((t) =>
                (t.records || []).forEach((r, i) => out.push({ ...r, key: `${e.id}:${t.id}:${i}`, at: e.at, via: e.name }))
            )
        );
        return out;
    }
    get canLink() {
        return this.context && this.context.isAgent;
    }
    get dataRows() {
        return [...this.allRecords].reverse().map((r) => ({
            ...r,
            opClass: 'nf-op nf-op_' + (r.op || '').toLowerCase(),
            href: r.recordId ? `/lightning/r/${r.recordId}/view` : null,
            showLink: this.canLink && !!r.recordId,
            shortId: r.recordId || '—'
        }));
    }
    get storedCount() {
        return this.allRecords.filter((r) => r.op !== 'READ').length;
    }
    get readCount() {
        return this.allRecords.filter((r) => r.op === 'READ').length;
    }
    get hasData() {
        return this.allRecords.length > 0;
    }

    // ── Context ──────────────────────────────────────────────────────────────

    get contextJson() {
        return pretty({ context: this.context, journey: this.journeyState });
    }

    // ── Handlers ─────────────────────────────────────────────────────────────

    handleTab(event) {
        this.tab = event.currentTarget.dataset.key;
    }
    handleFilter(event) {
        this.filter = event.currentTarget.dataset.key;
    }
    toggle(event) {
        const id = event.currentTarget.dataset.id;
        this.expanded = { ...this.expanded, [id]: !this.expanded[id] };
    }
    handleClear() {
        this.expanded = {};
        clearLog();
    }
    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
    async handleCopy(event) {
        const id = event.currentTarget.dataset.id;
        const entry = this.entries.find((e) => e.id === id);
        const text = JSON.stringify(entry, null, 2);
        try {
            await navigator.clipboard.writeText(text);
            this.copiedId = id;
        } catch (e) {
            this.copiedId = null;
        }
    }
}
