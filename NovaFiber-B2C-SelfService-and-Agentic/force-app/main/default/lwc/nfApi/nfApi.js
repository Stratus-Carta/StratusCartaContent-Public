/**
 * nfApi — the only place the NovaFiber LWCs talk to Apex.
 *
 * Every NF_JourneyController method returns an Envelope { dataJson, error, trace, limits, serverMs }.
 * This module unwraps it, throws the customer-safe error, and — when the Journey Inspector is on —
 * appends one log entry per call (client round trip + the server's NF_Trace) for nfInspector.
 */
import apexCatalogPreview from '@salesforce/apex/NF_JourneyController.getCatalogPreview';
import apexCheck from '@salesforce/apex/NF_JourneyController.checkServiceability';
import apexOverride from '@salesforce/apex/NF_JourneyController.overrideServiceability';
import apexOffers from '@salesforce/apex/NF_JourneyController.getOffers';
import apexStartCart from '@salesforce/apex/NF_JourneyController.startCart';
import apexSync from '@salesforce/apex/NF_JourneyController.syncCart';
import apexPrice from '@salesforce/apex/NF_JourneyController.priceCart';
import apexPoll from '@salesforce/apex/NF_JourneyController.getRequestResult';
import apexSubmit from '@salesforce/apex/NF_JourneyController.submitOrder';
import apexSearch from '@salesforce/apex/NF_JourneyController.searchAccounts';
import apexDiscard from '@salesforce/apex/NF_JourneyController.discardJourney';
import apexFlush from '@salesforce/apex/NF_JourneyController.flushJourneyCache';
import apexCheckSites from '@salesforce/apex/NF_JourneyController.checkSites';
import apexStatePrices from '@salesforce/apex/NF_JourneyController.getStatePrices';
import apexPriceSiteCarts from '@salesforce/apex/NF_JourneyController.priceSiteCarts';
import apexSaveMultiSite from '@salesforce/apex/NF_JourneyController.saveMultiSiteQuote';
import apexInstallSites from '@salesforce/apex/NF_JourneyController.getInstallSites';
import apexInstallSlots from '@salesforce/apex/NF_JourneyController.getInstallSlots';
import apexBookInstall from '@salesforce/apex/NF_JourneyController.bookInstall';
import apexPrepareAgreement from '@salesforce/apex/NF_JourneyController.prepareAgreement';
import apexGetAgreement from '@salesforce/apex/NF_JourneyController.getAgreement';
import apexStartSigning from '@salesforce/apex/NF_JourneyController.startSigning';
import apexCompleteSigning from '@salesforce/apex/NF_JourneyController.completeSigning';
import apexAgentStart from '@salesforce/apex/NF_AgentGateway.startChat';
import apexAgentSend from '@salesforce/apex/NF_AgentGateway.sendMessage';
import apexAgentCustomer from '@salesforce/apex/NF_AgentGateway.saveCustomer';
import apexAgentEnd from '@salesforce/apex/NF_AgentGateway.endChat';
import apexPortalLogin from '@salesforce/apex/NF_PortalController.login';
import apexPortalDashboard from '@salesforce/apex/NF_PortalController.getDashboard';
import apexPortalLogout from '@salesforce/apex/NF_PortalController.logout';

const POLL_INTERVAL_MS = 1000;
const POLL_TIMEOUT_MS = 60000;
const MAX_LOG = 200;

let debug = false;
/** Journey mode sent with cache-aware calls: 'Cached' | 'Realtime' (null = org default). */
let mode = null;
let log = [];
let seq = 0;
const listeners = new Set();

function emit() {
    listeners.forEach((fn) => fn(log));
}

export function setDebug(value) {
    debug = !!value;
}
export function setMode(value) {
    mode = value || null;
}
export function isDebug() {
    return debug;
}
export function subscribe(fn) {
    listeners.add(fn);
    fn(log);
    return () => listeners.delete(fn);
}
export function clearLog() {
    log = [];
    emit();
}

/** Same masking as NF_Trace.mask: emails and phone numbers never reach the inspector. */
function mask(value) {
    if (value === null || value === undefined) {
        return value;
    }
    const masked = JSON.stringify(value)
        // passwords and session tokens never reach the inspector (also inside nested JSON strings)
        .replace(/(\\?"(?:portalPassword|password|token|bookingToken)\\?"\s*:\s*\\?")[^"\\]*(\\?")/g, '$1••••••$2')
        .replace(/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)/g, '$1***@$2')
        .replace(/(\+?\d[\d ()\-.]{6,}\d)(\d{2})/g, '***-***-**$2');
    return JSON.parse(masked);
}

function parse(json) {
    if (!json) {
        return null;
    }
    try {
        return JSON.parse(json);
    } catch (e) {
        return json;
    }
}

/** Adds (or, for repeated polls, merges into) a log entry. */
function record(entry) {
    const last = log[log.length - 1];
    if (entry.coalesceKey && last && last.coalesceKey === entry.coalesceKey) {
        last.count += 1;
        last.clientMs += entry.clientMs;
        last.status = entry.status;
        last.response = entry.response;
        last.error = entry.error;
        last.trace = last.trace.concat(entry.trace);
        last.limits = entry.limits;
        log = [...log];
    } else {
        log = [...log, entry].slice(-MAX_LOG);
    }
    emit();
}

async function call(name, apexFn, params, coalesceKey) {
    const started = Date.now();
    let env;
    try {
        env = await apexFn({ ...params, debug });
    } catch (e) {
        // Transport failure (not a business error): still visible in the inspector.
        if (debug) {
            record({
                id: `c${++seq}`, name, at: started, clientMs: Date.now() - started, count: 1,
                status: 'ERROR', params: mask(params), response: null, error: e?.body?.message || e?.message, trace: [], limits: null
            });
        }
        throw e;
    }
    if (debug) {
        record({
            id: `c${++seq}`,
            name,
            at: started,
            clientMs: Date.now() - started,
            serverMs: env.serverMs,
            count: 1,
            coalesceKey,
            status: env.error ? 'ERROR' : 'OK',
            params: mask(params),
            response: mask(parse(env.dataJson)),
            error: env.error,
            trace: env.trace || [],
            limits: env.limits
        });
    }
    if (env.error) {
        throw new Error(env.error);
    }
    return parse(env.dataJson);
}

const sleep = (ms) =>
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Guest visitors cannot run createOrderFromQuote; the server queues the order
 * (NF_JourneyWorker) and returns a pendingRequestKey. Waits for it and returns the result.
 */
async function settle(response) {
    if (!response || !response.pendingRequestKey) {
        return response;
    }
    const key = response.pendingRequestKey;
    const started = Date.now();
    while (Date.now() - started < POLL_TIMEOUT_MS) {
        // eslint-disable-next-line no-await-in-loop
        await sleep(POLL_INTERVAL_MS);
        // eslint-disable-next-line no-await-in-loop
        const r = await call('getRequestResult', apexPoll, { requestKey: key }, `poll:${key}`);
        if (r.status === 'Completed') {
            return parse(r.resultJson);
        }
        if (r.status === 'Failed') {
            throw new Error(r.error || 'Something went wrong. Please try again.');
        }
    }
    throw new Error('This is taking longer than expected. Please try again.');
}

export const api = {
    catalogPreview: () => call('getCatalogPreview', apexCatalogPreview, { mode }),
    checkServiceability: (address) =>
        call('checkServiceability', apexCheck, { addressJson: JSON.stringify(address), mode }),
    overrideServiceability: (svc) =>
        call('overrideServiceability', apexOverride, { serviceabilityJson: JSON.stringify(svc) }),
    getOffers: (svc) => call('getOffers', apexOffers, { serviceabilityJson: JSON.stringify(svc), mode }),
    /** Opens a configurator session in the background, ahead of the first cart change. */
    startCart: () => call('startCart', apexStartCart, { mode }),
    /** Every cart change: Revenue Cloud configurator session → live prices + rule messages. */
    syncCart: (cartJson) => call('syncCart', apexSync, { cartJson, mode }),
    /** "Get my quote": saves the configured cart on the quote. */
    priceCart: (cartJson) => call('priceCart', apexPrice, { cartJson, mode }),
    submitOrder: async (quoteId, customer) =>
        settle(await call('submitOrder', apexSubmit, { quoteId, customerJson: JSON.stringify(customer) })),
    searchAccounts: (term) => call('searchAccounts', apexSearch, { term }),
    /** Deletes the journey's draft quote (and prospect account). */
    discardJourney: (quoteId) => call('discardJourney', apexDiscard, { quoteId }),
    /** Agents: invalidates every cached serviceability, catalog, offer and priced-cart entry. */
    flushCache: () => call('flushJourneyCache', apexFlush, {}),

    // Multi-site quoting (agents): many service locations, each priced by its state
    /** Serviceability + qualified plans for up to 10 sites. */
    checkSites: (sites) => call('checkSites', apexCheckSites, { sitesJson: JSON.stringify(sites), mode }),
    /** Browse-time location prices { states, productIds } → [{ state, prices: { productId: price } }]; nothing saved. */
    statePrices: (request) => call('getStatePrices', apexStatePrices, { requestJson: JSON.stringify(request), mode }),
    /** Every site's cart priced for its state (configurator, nothing saved). */
    priceSiteCarts: (sites) => call('priceSiteCarts', apexPriceSiteCarts, { sitesJson: JSON.stringify(sites), mode }),
    /** One quote with a service location + line group per site. */
    saveMultiSiteQuote: (request) =>
        call('saveMultiSiteQuote', apexSaveMultiSite, { requestJson: JSON.stringify(request), mode }),

    // AI journey: the NovaFiber sales agent (Agentforce) through NF_AgentGateway
    /** Opens an agent session; returns the journey view with the welcome message. */
    // Installation booking (Field Service): the booking token proves the visitor placed the order.
    installSites: (orderId, bookingToken) => call('getInstallSites', apexInstallSites, { orderId, bookingToken }),
    installSlots: (orderId, bookingToken, siteKey) => call('getInstallSlots', apexInstallSlots, { orderId, bookingToken, siteKey }),
    bookInstall: (orderId, bookingToken, siteKey, slotKey) =>
        call('bookInstall', apexBookInstall, { orderId, bookingToken, siteKey, slotKey }),
    // Agreements / proposals (native document templates) and e-signature
    prepareAgreement: (quoteId, signer) => call('prepareAgreement', apexPrepareAgreement, { quoteId, signerJson: JSON.stringify(signer) }),
    getAgreement: (quoteId, processId) => call('getAgreement', apexGetAgreement, { quoteId, processId }, `agreement:${quoteId}`),
    startSigning: (quoteId, signer, returnUrl, pageOrigin) =>
        call('startSigning', apexStartSigning, { quoteId, signerJson: JSON.stringify(signer), returnUrl, pageOrigin }),
    completeSigning: (quoteId, envelopeId, signer, typedSignature) =>
        call('completeSigning', apexCompleteSigning, { quoteId, envelopeId, signerJson: JSON.stringify(signer), typedSignature }),
    agentStart: () => call('startChat', apexAgentStart, {}),
    /** One customer message; returns the agent's replies and the journey its actions built. */
    agentSend: (journeyKey, text) => call('sendMessage', apexAgentSend, { journeyKey, text }),
    /** Secure checkout form: contact details go to the journey, never to the language model. */
    agentSaveCustomer: (journeyKey, customer) =>
        call('saveCustomer', apexAgentCustomer, { journeyKey, customerJson: JSON.stringify(customer) }),
    /** Ends the agent session; discard also deletes the draft quote and the chat journey. */
    agentEnd: (journeyKey, discard) => call('endChat', apexAgentEnd, { journeyKey, discard: !!discard }),

    // My NovaFiber customer portal (NF_PortalController)
    /** Returns { token, dashboard }; the token is kept for this browser tab only. */
    portalLogin: (username, password) => call('login', apexPortalLogin, { username, password }),
    portalDashboard: (token) => call('getDashboard', apexPortalDashboard, { token }, `portal:${token}`),
    portalLogout: (token) => call('logout', apexPortalLogout, { token })
};
