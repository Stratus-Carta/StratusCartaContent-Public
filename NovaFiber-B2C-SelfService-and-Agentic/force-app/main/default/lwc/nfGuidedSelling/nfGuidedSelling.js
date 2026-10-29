import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import getContext from '@salesforce/apex/NF_JourneyController.getContext';
import { api as nfApi, setDebug, setMode } from 'c/nfApi';
import { STEPS, nextKey, progressFor, reduceError, toCartRequest } from 'c/nfUtils';

const ACCOUNT_NAME = 'Account.Name';
const MAX_LINES = 5;
const SYNC_DELAY_MS = 450;
const INSPECTOR_WIDTH_PREF = 'nf.inspectorWidth';
const INSPECTOR_DEFAULT_WIDTH = 440;
const INSPECTOR_MIN_WIDTH = 320;

function readWidthPref() {
    try {
        const v = Number(window.localStorage.getItem(INSPECTOR_WIDTH_PREF));
        return v >= INSPECTOR_MIN_WIDTH ? v : INSPECTOR_DEFAULT_WIDTH;
    } catch (e) {
        return INSPECTOR_DEFAULT_WIDTH;
    }
}
const MODE_PREF = 'nf.journeyMode';
const MODES = [
    { value: 'Cached', label: 'Cached', title: 'Repeated serviceability checks, catalog, offers and already-priced carts come from the org cache' },
    { value: 'Realtime', label: 'Realtime', title: 'Every step calls the serviceability API and Revenue Cloud live' }
];
function readModePref() {
    try {
        const v = window.localStorage.getItem(MODE_PREF);
        return MODES.some((m) => m.value === v) ? v : null;
    } catch (e) {
        return null;
    }
}
function writeModePref(value) {
    try {
        window.localStorage.setItem(MODE_PREF, value);
    } catch (e) {
        // storage unavailable: the mode still applies for this page view
    }
}

function writeWidthPref(value) {
    try {
        window.localStorage.setItem(INSPECTOR_WIDTH_PREF, String(value));
    } catch (e) {
        // storage unavailable: the width still applies for this page view
    }
}
const INSPECTOR_PREF = 'nf.inspectorOpen';

function readPref() {
    try {
        return window.sessionStorage.getItem(INSPECTOR_PREF);
    } catch (e) {
        return null;
    }
}
function writePref(value) {
    try {
        window.sessionStorage.setItem(INSPECTOR_PREF, value ? '1' : '0');
    } catch (e) {
        // storage unavailable (private mode): the toggle still works for this page view
    }
}
const AI_PREF = 'nf.aiJourney';
/** AI journey on: ?ai=1 in the URL, or chosen earlier in this browser tab. */
function readAiPref() {
    try {
        const param = new URLSearchParams(window.location.search).get('ai');
        if (param === '1' || param === '0') {
            return param === '1';
        }
        return window.sessionStorage.getItem(AI_PREF) === '1';
    } catch (e) {
        return false;
    }
}
function writeAiPref(value) {
    try {
        window.sessionStorage.setItem(AI_PREF, value ? '1' : '0');
    } catch (e) {
        // storage unavailable: the choice still applies for this page view
    }
}
const PORTAL_PREF = 'nf.portalView';
/** My NovaFiber portal open: ?portal=1, or chosen earlier in this tab. */
function readPortalPref() {
    try {
        if (new URLSearchParams(window.location.search).get('portal') === '1') {
            return true;
        }
        return window.sessionStorage.getItem(PORTAL_PREF) === '1';
    } catch (e) {
        return false;
    }
}
function writePortalPref(value) {
    try {
        window.sessionStorage.setItem(PORTAL_PREF, value ? '1' : '0');
    } catch (e) {
        // storage unavailable: the choice still applies for this page view
    }
}
function urlRequestsDebug() {
    try {
        return new URLSearchParams(window.location.search).get('debug') === '1';
    } catch (e) {
        return false;
    }
}

/**
 * NovaFiber guided selling journey: Address → Serviceability → Plans → Quote → Checkout → Order.
 * One component for both channels. The server decides the channel (self-service vs agent),
 * which agent capabilities are unlocked and whether the Journey Inspector may be shown.
 */
export default class NfGuidedSelling extends NavigationMixin(LightningElement) {
    @api heroTitle = 'Fiber that keeps up with everyone at home.';
    @api heroSubtitle = 'Symmetrical speeds up to 2 Gig, TV that follows you to every screen and mobile plans on one bill. Check your address to see exactly what you can get.';
    /** Set automatically on an Account record page: the sale is placed on that account. */
    @api recordId;

    context;
    loadError;
    step = 'address';
    busy = false;
    busyMessage = 'Working';
    error;
    notice;
    confirmingDiscard = false;

    inspectorAvailable = false;
    inspectorOpen = false;
    inspectorWidth = readWidthPref();
    journeyMode; // Cached | Realtime
    resizeCleanup;

    preview = [];
    address;
    serviceability;
    categories = [];
    cart = [];
    /** Live cart from the Revenue Cloud configurator (QuoteSummary: draft quote, prices, messages). */
    cartState;
    syncing = false;
    syncSeq = 0;
    syncTimer;
    configuring; // { offer, key, selections }
    pendingPlanId;
    quote;
    order;
    account; // agent-selected { accountId, name }
    /** Shop by chatting with Nova (Agentforce) instead of the guided steps. */
    aiMode = readAiPref();
    /** Nova's chat stays mounted (hidden) once started, so going Home and back keeps the conversation. */
    aiStarted = this.aiMode;
    /** My NovaFiber customer portal (login + order tracking). */
    portalMode = readPortalPref();
    portalUsername;
    /** Quote many service locations at once, each priced by its state (nfMultiSite): agents and business visitors. */
    multiSiteMode = false;
    /** Checkout details (with the portal password) kept for the order; the signer view of them has no password. */
    customer;
    signer;

    connectedCallback() {
        getContext()
            .then((ctx) => {
                this.context = ctx;
                // Agents always; site visitors whenever NF_Journey_Setting__mdt allows it (closed unless ?debug=1).
                this.inspectorAvailable = ctx.inspectorAllowed;
                // The org default applies; agents and debug visitors may switch (remembered per browser).
                this.journeyMode = (this.showModeSwitch && readModePref()) || ctx.journeyMode || 'Cached';
                setMode(this.journeyMode);
                const pref = readPref();
                this.inspectorOpen = this.inspectorAvailable && (pref !== null ? pref === '1' : urlRequestsDebug());
                this.syncDebug();
                if (!ctx.isAgent) {
                    this.loadPreview();
                }
            })
            .catch((e) => {
                this.loadError = reduceError(e);
            });
    }

    disconnectedCallback() {
        window.clearTimeout(this.syncTimer);
        if (this.resizeCleanup) {
            this.resizeCleanup();
        }
    }

    async loadPreview() {
        try {
            this.preview = (await nfApi.catalogPreview()) || [];
        } catch (e) {
            this.preview = []; // landing still works without the live price preview
        }
    }

    @wire(getRecord, { recordId: '$accountRecordId', fields: [ACCOUNT_NAME] })
    wiredAccount({ data }) {
        if (data && !this.account) {
            this.account = { accountId: this.recordId, name: getFieldValue(data, ACCOUNT_NAME) };
        }
    }
    get accountRecordId() {
        return this.recordId && this.recordId.startsWith('001') ? this.recordId : undefined;
    }

    // ── View state ───────────────────────────────────────────────────────────

    get isAgent() {
        return !!(this.context && this.context.isAgent);
    }
    get brandTag() {
        return this.isAgent ? 'Guided Selling' : 'Residential';
    }
    get accountName() {
        return this.account?.name;
    }
    get currencyCode() {
        return this.context?.currencyIsoCode || 'USD';
    }
    get showLanding() {
        return !this.isAgent;
    }
    get showFooter() {
        return !this.isAgent;
    }
    get showSteps() {
        return this.showGuided && (this.isAgent || this.step !== 'address');
    }
    get showGuided() {
        return !this.aiMode && !this.portalMode && !this.multiSiteMode;
    }
    get multiSiteButtonClass() {
        return 'nf-ai-toggle' + (this.multiSiteMode ? ' nf-ai-toggle_on' : '');
    }
    get multiSitePressed() {
        return this.multiSiteMode ? 'true' : 'false';
    }
    get multiSiteButtonLabel() {
        if (this.isAgent) return this.multiSiteMode ? 'Single site' : 'Multi-site';
        return this.multiSiteMode ? 'For home' : 'For business';
    }
    /** Cached / Realtime switch: agents, and visitors who opened the site with ?debug=1. */
    get showModeSwitch() {
        return !!this.context && this.context.inspectorAllowed && (this.context.isAgent || urlRequestsDebug());
    }
    /** Agents always trace (the inspector is their tool); visitors only while the inspector is open. */
    syncDebug() {
        setDebug(this.inspectorAvailable && (this.isAgent || this.inspectorOpen));
    }
    toggleMultiSite() {
        this.multiSiteMode = !this.multiSiteMode;
        if (this.multiSiteMode && this.aiMode) {
            this.aiMode = false;
            writeAiPref(false);
        }
        this.error = undefined;
        this.notice = undefined;
        this.confirmingDiscard = false;
        this.scrollTop();
    }
    get showAiPromo() {
        return this.showGuided && this.step === 'address';
    }
    get showPortalButton() {
        return !!this.context && !this.isAgent;
    }
    get portalButtonClass() {
        return 'nf-portal-toggle' + (this.portalMode ? ' nf-portal-toggle_on' : '');
    }
    get portalPressed() {
        return this.portalMode ? 'true' : 'false';
    }
    togglePortal() {
        this.setPortalMode(!this.portalMode);
    }
    setPortalMode(on) {
        this.portalMode = on;
        writePortalPref(on);
        if (on) this.multiSiteMode = false;
        if (on && this.aiMode) {
            this.aiMode = false;
            writeAiPref(false);
        }
        this.error = undefined;
        this.notice = undefined;
        this.scrollTop();
    }
    /** "Track my order" on an order confirmation (guided or AI journey). */
    handleTrack(event) {
        this.portalUsername = event.detail?.username;
        this.setPortalMode(true);
    }
    handlePortalShop() {
        this.setPortalMode(false);
    }
    get aiButtonLabel() {
        return this.aiMode ? 'Guided steps' : 'Ask Nova (AI)';
    }
    get aiPressed() {
        return this.aiMode ? 'true' : 'false';
    }
    get aiButtonClass() {
        return 'nf-ai-toggle' + (this.aiMode ? ' nf-ai-toggle_on' : '');
    }
    toggleAi() {
        this.setAiMode(!this.aiMode);
    }
    handleAiExit() {
        this.aiStarted = false;   // the chat was ended: a later "Ask Nova" starts a new one
        this.setAiMode(false);
    }
    get aiClass() {
        return this.aiMode ? 'nf-ai' : 'nf-ai nf-hidden';
    }
    setAiMode(on) {
        if (on) {
            this.aiStarted = true;
            this.multiSiteMode = false;
        }
        this.aiMode = on;
        writeAiPref(on);
        if (on && this.portalMode) {
            this.portalMode = false;
            writePortalPref(false);
        }
        this.error = undefined;
        this.notice = undefined;
        this.confirmingDiscard = false;
        this.scrollTop();
    }
    get inspectorButtonLabel() {
        return this.inspectorOpen ? 'Inspector on' : 'Inspector';
    }
    get inspectorPressed() {
        return this.inspectorOpen ? 'true' : 'false';
    }
    get inspectorButtonClass() {
        return 'nf-insp-toggle' + (this.inspectorOpen ? ' nf-insp-toggle_on' : '');
    }
    get planHint() {
        if (!this.pendingPlanId) {
            return null;
        }
        const offer = this.previewOffer(this.pendingPlanId);
        return offer ? `Enter your address to check ${offer.name}.` : null;
    }
    // ── Back / discard ───────────────────────────────────────────────────────

    get canGoBack() {
        return ['offers', 'review', 'checkout'].includes(this.step);
    }
    get backLabel() {
        if (this.step === 'offers') {
            return this.configuring ? 'Back to plans' : 'Back to address';
        }
        return this.step === 'review' ? 'Back to plans' : 'Back to quote';
    }
    /** Anything to throw away: a cart, or a draft quote in Revenue Cloud. Orders are never discarded. */
    get canDiscard() {
        return this.step !== 'done' && !this.order && (this.cart.length > 0 || !!this.cartSession.quoteId);
    }
    get showToolbar() {
        return this.showGuided && (this.canGoBack || this.canDiscard);
    }
    get discardDescription() {
        const quote = this.quote?.quoteNumber || this.cartState?.quoteNumber;
        return quote
            ? `Your cart and quote ${quote} will be deleted, together with the details we saved for it. This can't be undone.`
            : 'Your cart will be emptied. Nothing has been saved yet, so there is nothing else to delete.';
    }

    handleBack() {
        this.confirmingDiscard = false;
        if (this.step === 'offers') {
            if (this.configuring) {
                this.configuring = undefined;
                return;
            }
            this.step = 'address';
        } else if (this.step === 'review') {
            this.step = 'offers';
        } else if (this.step === 'checkout') {
            this.step = 'review';
        } else if (this.step === 'sign') {
            this.step = 'checkout';
        }
        this.scrollTop();
    }

    handleDiscardAsk() {
        this.confirmingDiscard = true;
    }
    handleDiscardCancel() {
        this.confirmingDiscard = false;
    }

    async handleDiscardConfirm() {
        this.confirmingDiscard = false;
        const quoteId = this.cartSession.quoteId;
        window.clearTimeout(this.syncTimer);
        this.syncSeq += 1; // ignore cart syncs still in flight
        this.syncing = false;
        // An unconfirmed cart only lived in a configurator session: nothing to delete server side.
        const result = quoteId
            ? await this.run('Discarding your journey', () => nfApi.discardJourney(quoteId))
            : { discarded: true, deleted: [] };
        if (result) {
            this.resetJourney();
            this.notice = result.deleted && result.deleted.length
                ? `Journey discarded. Deleted: ${result.deleted.join(', ')}.`
                : 'Journey discarded. Nothing had been saved yet.';
        }
    }

    dismissNotice() {
        this.notice = undefined;
    }

    get isAddressStep() {
        return this.step === 'address';
    }
    get isOffersStep() {
        return this.step === 'offers';
    }
    get isReviewStep() {
        return this.step === 'review';
    }
    /** Steps and tips the progress toast walks through while the current action runs. */
    get busyProgress() {
        return progressFor(this.busyMessage);
    }
    get placeOrderLabel() {
        return this.isAgent ? 'Place order' : 'Place my order';
    }
    get isSignStep() {
        return this.step === 'sign';
    }
    get isCheckoutStep() {
        return this.step === 'checkout';
    }
    get isDoneStep() {
        return this.step === 'done';
    }
    get stepsView() {
        const current = STEPS.findIndex((s) => s.key === this.step);
        return STEPS.map((s, i) => ({
            ...s,
            number: i + 1,
            ariaCurrent: i === current ? 'step' : null,
            cssClass: 'nf-step' + (i < current ? ' nf-step_done' : i === current ? ' nf-step_current' : '')
        }));
    }
    get categoriesView() {
        const inCart = {};
        this.cart.forEach((i) => {
            inCart[i.offer.productId] = (inCart[i.offer.productId] || 0) + i.quantity;
        });
        return this.categories.map((c) => ({
            ...c,
            offers: c.offers.map((o) => ({
                offer: o,
                inCart: inCart[o.productId] || 0,
                showConfig: this.configuring?.offer?.productId === o.productId,
                configKey: `cfg-${o.productId}`
            }))
        }));
    }
    get noOffers() {
        return this.categories.length === 0;
    }
    /** What the inspector's Context tab shows. */
    get journeyState() {
        return {
            step: this.step,
            address: this.address || null,
            serviceability: this.serviceability
                ? {
                      id: this.serviceability.serviceabilityId,
                      status: this.serviceability.status,
                      overridden: this.serviceability.overridden,
                      technologies: (this.serviceability.technologies || []).map(
                          (t) => `${t.technology} ${t.maxDownloadMbps} Mbps`
                      )
                  }
                : null,
            cart: this.cart.map((i) => ({
                product: i.offer.name,
                quantity: i.quantity,
                options: Object.keys(i.options).length,
                discountPercent: i.discountPercent
            })),
            cartSession: this.cartState
                ? {
                      draftQuote: this.cartState.quoteNumber,
                      configuratorContext: this.cartState.contextId,
                      monthly: this.cartState.monthlyTotal,
                      messages: (this.cartState.messages || []).length
                  }
                : null,
            quote: this.quote ? { id: this.quote.quoteId, number: this.quote.quoteNumber, monthly: this.quote.monthlyTotal } : null,
            order: this.order ? { id: this.order.orderId, number: this.order.orderNumber, status: this.order.status } : null,
            account: this.account || null
        };
    }

    // ── Async helper ─────────────────────────────────────────────────────────

    async run(message, fn) {
        this.busy = true;
        this.busyMessage = message;
        this.error = undefined;
        try {
            return await fn();
        } catch (e) {
            this.error = reduceError(e);
            return undefined;
        } finally {
            this.busy = false;
        }
    }

    // ── Inspector ────────────────────────────────────────────────────────────

    toggleInspector() {
        this.inspectorOpen = !this.inspectorOpen;
        writePref(this.inspectorOpen);
        this.syncDebug();
    }

    // ── Journey mode / cache ─────────────────────────────────────────────────

    get modeOptions() {
        return MODES.map((m) => ({
            ...m,
            checked: m.value === this.journeyMode ? 'true' : 'false',
            cssClass: 'nf-mode-btn' + (m.value === this.journeyMode ? ' nf-mode-btn_on' : '')
        }));
    }
    get canFlushCache() {
        return !!(this.context && this.context.canFlushCache);
    }

    handleModeChange(event) {
        this.journeyMode = event.currentTarget.dataset.mode;
        setMode(this.journeyMode);
        writeModePref(this.journeyMode);
        this.notice = `${this.journeyMode} journey: ${
            this.journeyMode === 'Cached'
                ? 'repeated steps are answered from the cache.'
                : 'every step calls the serviceability API and Revenue Cloud live.'
        }`;
    }

    async handleFlushCache() {
        const result = await this.run('Flushing the journey cache', () => nfApi.flushCache());
        if (result) {
            this.notice = `Journey cache flushed (generation ${result.generation}). The next steps go to Revenue Cloud live.`;
        }
    }

    get sideStyle() {
        return `--nf-insp-w: ${this.inspectorWidth}px`;
    }
    /** The journey keeps at least 480px; the inspector can take the rest. */
    get maxInspectorWidth() {
        const row = this.template.querySelector('.nf-row');
        const total = row ? row.getBoundingClientRect().width : window.innerWidth;
        return Math.max(INSPECTOR_MIN_WIDTH, Math.round(total - 480));
    }
    setInspectorWidth(px) {
        this.inspectorWidth = Math.round(Math.min(this.maxInspectorWidth, Math.max(INSPECTOR_MIN_WIDTH, px)));
    }

    handleResizeStart(event) {
        event.preventDefault();
        const row = this.template.querySelector('.nf-row');
        const right = row ? row.getBoundingClientRect().right : window.innerWidth;
        const app = this.template.querySelector('.nf-app');
        if (app) {
            app.classList.add('nf-resizing');
        }
        const move = (e) => this.setInspectorWidth(right - e.clientX);
        const stop = () => {
            window.removeEventListener('pointermove', move);
            window.removeEventListener('pointerup', stop);
            window.removeEventListener('pointercancel', stop);
            if (app) {
                app.classList.remove('nf-resizing');
            }
            this.resizeCleanup = undefined;
            writeWidthPref(this.inspectorWidth);
        };
        window.addEventListener('pointermove', move);
        window.addEventListener('pointerup', stop);
        window.addEventListener('pointercancel', stop);
        this.resizeCleanup = stop;
    }

    handleResizeKey(event) {
        const step = event.shiftKey ? 80 : 24;
        if (event.key === 'ArrowLeft') {
            this.setInspectorWidth(this.inspectorWidth + step);
        } else if (event.key === 'ArrowRight') {
            this.setInspectorWidth(this.inspectorWidth - step);
        } else {
            return;
        }
        event.preventDefault();
        writeWidthPref(this.inspectorWidth);
    }

    handleResizeReset() {
        this.inspectorWidth = INSPECTOR_DEFAULT_WIDTH;
        writeWidthPref(this.inspectorWidth);
    }

    // ── Landing ──────────────────────────────────────────────────────────────

    previewOffer(productId) {
        for (const c of this.preview || []) {
            const o = c.offers.find((x) => x.productId === productId);
            if (o) {
                return o;
            }
        }
        return undefined;
    }

    handleChoosePlan(event) {
        this.pendingPlanId = event.detail.productId;
        const form = this.template.querySelector('.nf-address');
        if (form) {
            form.scrollIntoView({ behavior: 'smooth', block: 'center' });
            form.focusFirst();
        }
    }

    // ── Address & serviceability ─────────────────────────────────────────────

    async handleCheck(event) {
        this.address = event.detail;
        await this.run('Checking availability', async () => {
            const result = await nfApi.checkServiceability(this.address);
            await this.applyServiceability(result);
        });
    }

    async handleOverride() {
        await this.run('Overriding serviceability', async () => {
            const result = await nfApi.overrideServiceability(this.serviceability);
            await this.applyServiceability(result);
        });
    }

    async applyServiceability(result) {
        this.serviceability = result;
        this.categories = (await nfApi.getOffers(result)) || [];
        // Drop cart items that no longer qualify at this address; a new address starts a new draft quote.
        const available = new Set(this.categories.flatMap((c) => c.offers.map((o) => o.productId)));
        this.cart = this.cart
            .filter((i) => available.has(i.offer.productId))
            .map((i) => ({ ...i, offer: this.findOffer(i.offer.productId) }));
        this.resetCartSession();
        this.prewarmCart();
        this.configuring = undefined;
        this.step = 'offers';
        // A plan chosen on the landing page opens straight in the configurator when it is available here.
        if (this.pendingPlanId) {
            const offer = this.findOffer(this.pendingPlanId);
            this.pendingPlanId = undefined;
            if (offer) {
                this.selectOffer(offer);
            }
        }
        this.scrollTop();
    }

    handleChangeAddress() {
        this.step = 'address';
    }

    /** Logo / Home: back to the homepage from anywhere. Carts and Nova's chat are kept; a finished order starts fresh. */
    handleHome(event) {
        if (event) {
            event.preventDefault();
        }
        if (this.aiMode) {
            this.aiMode = false;
            writeAiPref(false);
        }
        if (this.portalMode) {
            this.portalMode = false;
            writePortalPref(false);
        }
        if (this.step === 'done') {
            this.resetJourney();
        } else {
            this.step = 'address';
            this.configuring = undefined;
        }
        this.confirmingDiscard = false;
        this.error = undefined;
        this.notice = undefined;
        this.scrollTop();
    }

    // ── Offers & cart ────────────────────────────────────────────────────────

    findOffer(productId) {
        for (const c of this.categories) {
            const o = c.offers.find((x) => x.productId === productId);
            if (o) {
                return o;
            }
        }
        return undefined;
    }

    handleSelectOffer(event) {
        this.selectOffer(this.findOffer(event.detail.productId));
    }

    selectOffer(offer) {
        if (offer.isBundle && offer.groups.length) {
            this.configuring = { offer, key: null, selections: null };
            this.scrollToConfigurator();
            return;
        }
        const existing = this.cart.find((i) => i.offer.productId === offer.productId);
        if (existing) {
            this.updateItem(existing.key, { quantity: Math.min(MAX_LINES, existing.quantity + 1) });
        } else {
            this.setCart([...this.cart, { key: nextKey('item'), offer, quantity: 1, options: {}, discountPercent: null }]);
        }
    }

    // ── Cart session (Revenue Cloud configurator) ────────────────────────────

    /** Every cart change goes through here so the configurator sees it. */
    setCart(cart) {
        this.cart = cart;
        this.scheduleSync();
    }

    /**
     * The configurator session the next sync continues (on the shared workspace quote) and the
     * customer's confirmed quote, if any.
     */
    get cartSession() {
        const contextId = this.cartState?.contextId || null;
        return {
            quoteId: this.cartState?.quoteId || this.quote?.quoteId,
            contextId,
            lineIds: contextId ? (this.cartState.lines || []).map((l) => l.lineId) : null
        };
    }

    resetCartSession() {
        // New address or account: a quote confirmed for the old one is deleted in the background.
        const previous = this.cartSession.quoteId;
        if (previous && !this.order) {
            nfApi.discardJourney(previous).catch(() => {
                // best effort: NF_JourneyCleanup removes abandoned quotes anyway
            });
        }
        this.cartState = undefined;
        this.quote = undefined;
        if (this.cart.length) {
            this.scheduleSync();
        }
    }

    /** Opens the configurator session while the shopper looks at the plans, so the first add is quick. */
    prewarmCart() {
        if (this.cartState?.contextId) {
            return;
        }
        const seq = this.syncSeq;
        nfApi
            .startCart()
            .then((session) => {
                // A cart change that started meanwhile opens (or already opened) its own session.
                if (seq === this.syncSeq && !this.cartState?.contextId) {
                    this.cartState = { ...session, quoteId: this.cartState?.quoteId, quoteNumber: this.cartState?.quoteNumber };
                }
            })
            .catch(() => {
                // the first cart change opens a session itself
            });
    }

    scheduleSync() {
        window.clearTimeout(this.syncTimer);
        this.syncSeq += 1; // responses for older carts are ignored
        if (!this.cart.length) {
            // Keep the session (its lines are replaced on the next change) and any confirmed quote.
            this.cartState = this.cartState ? { ...this.cartState, messages: [], hasErrors: false } : undefined;
            this.syncing = false;
            return;
        }
        this.syncing = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.syncTimer = window.setTimeout(() => this.syncNow(), SYNC_DELAY_MS);
    }

    async syncNow() {
        const seq = this.syncSeq;
        try {
            const state = await nfApi.syncCart(
                toCartRequest(this.cart, this.serviceability, this.cartSession, this.account?.accountId)
            );
            if (seq === this.syncSeq) {
                this.cartState = state;
                this.followRules(state);
                this.error = undefined;
            }
        } catch (e) {
            if (seq === this.syncSeq) {
                this.error = reduceError(e);
            }
        } finally {
            if (seq === this.syncSeq) {
                this.syncing = false;
            }
        }
    }

    /**
     * The configuration rules (CML) may add or remove options: the cart takes what Revenue Cloud left, without
     * another sync (the session already holds exactly that). Their note shows on the item.
     */
    followRules(state) {
        const adjustments = state?.ruleAdjustments || [];
        if (!adjustments.length) {
            return;
        }
        const byKey = new Map(adjustments.map((a) => [a.itemKey, a]));
        this.cart = this.cart.map((i) => {
            const a = byKey.get(i.key);
            return a ? { ...i, options: Object.fromEntries((a.options || []).map((o) => [o.componentId, o.quantity])) } : i;
        });
    }

    /** Options the configuration rules hide for the item being configured: { componentId: 'hide' | 'disable' }. */
    get ruleHidden() {
        const key = this.configuring?.key;
        const out = {};
        (this.cartState?.hiddenOptions || []).filter((h) => key && h.itemKey === key).forEach((h) => {
            out[h.componentId] = h.treatment;
        });
        return out;
    }

    scrollToConfigurator() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const el = this.template.querySelector('.nf-configurator');
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            }
        });
    }

    scrollTop() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const el = this.template.querySelector('.nf-main');
            if (el && el.getBoundingClientRect().top < 0) {
                el.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        });
    }

    handleConfigConfirm(event) {
        const { selections } = event.detail;
        if (this.configuring.key) {
            this.updateItem(this.configuring.key, { options: selections });
        } else {
            this.setCart([
                ...this.cart,
                { key: nextKey('item'), offer: this.configuring.offer, quantity: 1, options: selections, discountPercent: null }
            ]);
        }
        this.configuring = undefined;
    }

    handleConfigCancel() {
        this.configuring = undefined;
    }

    updateItem(key, patch) {
        this.setCart(this.cart.map((i) => (i.key === key ? { ...i, ...patch } : i)));
    }

    handleCartEdit(event) {
        const item = this.cart.find((i) => i.key === event.detail.key);
        this.configuring = { offer: item.offer, key: item.key, selections: { ...item.options } };
        this.scrollToConfigurator();
    }

    handleCartRemove(event) {
        this.setCart(this.cart.filter((i) => i.key !== event.detail.key));
        if (this.configuring?.key === event.detail.key) {
            this.configuring = undefined;
        }
    }

    handleCartQuantity(event) {
        const item = this.cart.find((i) => i.key === event.detail.key);
        this.updateItem(item.key, { quantity: Math.max(1, Math.min(MAX_LINES, item.quantity + event.detail.delta)) });
    }

    handleCartDiscount(event) {
        this.updateItem(event.detail.key, { discountPercent: event.detail.value });
    }

    handleAccountChange(event) {
        this.account = event.detail.account;
        this.resetCartSession(); // the draft quote belongs to the previous account
    }

    // ── Quote ────────────────────────────────────────────────────────────────

    async handleQuote() {
        window.clearTimeout(this.syncTimer);
        this.syncSeq += 1; // the save configures the latest cart itself
        this.syncing = false;
        const summary = await this.run('Saving your quote in Revenue Cloud', () =>
            nfApi.priceCart(toCartRequest(this.cart, this.serviceability, this.cartSession, this.account?.accountId))
        );
        if (summary) {
            // The configurator's messages for this cart still apply to the confirmed quote.
            this.quote = { ...summary, messages: this.cartState?.messages || [] };
            this.cartState = { ...(this.cartState || {}), quoteId: summary.quoteId, quoteNumber: summary.quoteNumber };
            this.step = 'review';
            this.scrollTop();
        }
    }

    handleBackToOffers() {
        this.step = 'offers';
    }

    handleToCheckout() {
        this.step = 'checkout';
        this.scrollTop();
    }

    handleBackToReview() {
        this.step = 'review';
    }

    // ── Order ────────────────────────────────────────────────────────────────

    /** Checkout details captured: next the service agreement (native Salesforce Contracts template) is signed. */
    handleCustomerDetails(event) {
        this.customer = event.detail;
        const { portalPassword, ...signer } = event.detail; // eslint-disable-line no-unused-vars
        this.signer = signer;
        this.step = 'sign';
        this.scrollTop();
    }
    handleBackToCheckout() {
        this.step = 'checkout';
    }
    handleAgreementSigned() {
        this.placeOrder();
    }
    handleAgreementSkipped() {
        this.placeOrder();
    }

    async placeOrder() {
        const result = await this.run('Placing your order', () => nfApi.submitOrder(this.quote.quoteId, this.customer));
        if (result) {
            this.order = result;
            this.step = 'done';
            this.scrollTop();
        }
    }

    handleRestart() {
        this.resetJourney();
    }

    resetJourney() {
        this.customer = undefined;
        this.signer = undefined;
        this.notice = undefined;
        this.confirmingDiscard = false;
        this.step = 'address';
        this.address = undefined;
        this.serviceability = undefined;
        this.categories = [];
        this.cart = [];
        window.clearTimeout(this.syncTimer);
        this.syncSeq += 1;
        this.syncing = false;
        this.cartState = undefined;
        this.configuring = undefined;
        this.quote = undefined;
        this.order = undefined;
        this.error = undefined;
        if (!this.accountRecordId) {
            this.account = undefined;
        }
    }

    // ── Misc ─────────────────────────────────────────────────────────────────

    handleOpenRecord(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.detail.recordId, objectApiName: event.detail.objectApiName, actionName: 'view' }
        });
    }

    handleChildError(event) {
        this.error = event.detail.message;
    }

    dismissError() {
        this.error = undefined;
    }
}
