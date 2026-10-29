import { LightningElement, api } from 'lwc';
import { api as nfApi } from 'c/nfApi';
import { SAMPLE_ADDRESSES, reduceError } from 'c/nfUtils';

const STEPS = [
    { key: 'address', label: 'Address' },
    { key: 'offers', label: 'Plans' },
    { key: 'cart', label: 'Cart' },
    { key: 'quote', label: 'Quote' },
    { key: 'done', label: 'Order' }
];
const THINKING = ['Nova is thinking', 'Checking with Revenue Cloud', 'Still working on it', 'Almost there'];
const THINKING_INTERVAL_MS = 2600;
const HIGHLIGHT_MS = 2600;
const SUGGESTIONS = {
    offers: ['What do you recommend for a family of four?', 'Show me plans under $60 a month', 'Which mobile plans can I add?'],
    cart: ['What add-ons can I get?', 'Get my quote', 'Empty my cart'],
    quote: ['What happens after I order?', 'I want to change my plans'],
    done: ['When will my installation be?']
};

let seq = 0;

/** Agent text → lines of plain and bold segments (no HTML from the model ever reaches the DOM). */
function formatText(text) {
    const lines = [];
    let blank = false;
    (text || '').split('\n').forEach((raw) => {
        const line = raw.trimEnd();
        if (!line.trim()) {
            blank = lines.length > 0;
            return;
        }
        const bullet = /^\s*[-*•]\s+/.test(line);
        const body = bullet ? line.replace(/^\s*[-*•]\s+/, '') : line.trim();
        const segments = body.split('**').map((part, i) => ({ key: `s${i}`, text: part, bold: i % 2 === 1 })).filter((s) => s.text);
        lines.push({
            key: `l${lines.length}`,
            bullet,
            segments,
            cssClass: 'aj-line' + (bullet ? ' aj-line_bullet' : '') + (blank ? ' aj-line_gap' : '')
        });
        blank = false;
    });
    return lines;
}

/**
 * NovaFiber AI journey: shop by chatting with Nova, the Agentforce sales agent (NF_Sales_Agent).
 * The chat goes through NF_AgentGateway (Agent API). The agent's actions run the same Revenue Cloud
 * journey as the guided flow, and the address result, plans, priced cart, quote and order it built
 * are shown next to the chat. Buttons on the cards simply send the agent a message, so the agent
 * stays in charge of the journey. Contact details are entered in the secure form, never in the chat.
 */
export default class NfAgentJourney extends LightningElement {
    @api currencyCode = 'USD';

    journeyKey;
    view;
    messages = [];
    draft = '';
    starting = true;
    sending = false;
    savingCustomer = false;
    showCheckout = false;
    showAgreement = false;
    signer;
    startError;
    notice;
    thinkingIndex = 0;
    thinkingTimer;
    scrollPending = false;
    highlightAddOns = false;
    highlightTimer;
    scrollToAddOns = false;

    connectedCallback() {
        this.start();
    }

    disconnectedCallback() {
        window.clearInterval(this.thinkingTimer);
        window.clearTimeout(this.highlightTimer);
    }

    renderedCallback() {
        if (this.scrollToAddOns) {
            const section = this.template.querySelector('c-nf-add-ons');
            if (section) {
                this.scrollToAddOns = false;
                section.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        }
        if (this.scrollPending) {
            this.scrollPending = false;
            const log = this.template.querySelector('.aj-log');
            if (log) {
                log.scrollTop = log.scrollHeight;
            }
        }
    }

    // ── Session ──────────────────────────────────────────────────────────────

    async start() {
        this.starting = true;
        this.startError = undefined;
        this.messages = [];
        this.view = undefined;
        this.journeyKey = undefined;
        this.showCheckout = false;
        try {
            this.apply(await nfApi.agentStart());
        } catch (e) {
            this.startError = reduceError(e);
        } finally {
            this.starting = false;
        }
    }

    apply(view) {
        this.journeyKey = view.journeyKey;
        this.view = view;
        (view.replies || []).forEach((text) => this.push('agent', text));
        if (view.step !== 'quote') {
            this.showCheckout = false;
        }
        if (view.focus === 'addons') {
            this.showCheckout = false;
            this.highlightAddOns = true;
            this.scrollToAddOns = true;
            window.clearTimeout(this.highlightTimer);
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.highlightTimer = window.setTimeout(() => {
                this.highlightAddOns = false;
            }, HIGHLIGHT_MS);
        }
    }

    push(from, text) {
        this.messages = [
            ...this.messages,
            {
                key: `m${++seq}`,
                isAgent: from === 'agent',
                isUser: from === 'user',
                isSystem: from === 'system',
                cssClass: `aj-msg aj-msg_${from}`,
                lines: formatText(text)
            }
        ];
        this.scrollPending = true;
    }

    async send(text) {
        const message = (text || '').trim();
        if (!message || this.sending || !this.journeyKey) {
            return;
        }
        this.push('user', message);
        this.draft = '';
        this.notice = undefined;
        this.sending = true;
        this.startThinking();
        try {
            this.apply(await nfApi.agentSend(this.journeyKey, message));
        } catch (e) {
            this.push('system', reduceError(e));
        } finally {
            this.sending = false;
            this.stopThinking();
            this.focusInput();
        }
    }

    startThinking() {
        this.thinkingIndex = 0;
        window.clearInterval(this.thinkingTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.thinkingTimer = window.setInterval(() => {
            this.thinkingIndex = Math.min(this.thinkingIndex + 1, THINKING.length - 1);
        }, THINKING_INTERVAL_MS);
        this.scrollPending = true;
    }

    stopThinking() {
        window.clearInterval(this.thinkingTimer);
    }

    focusInput() {
        const input = this.template.querySelector('.aj-input');
        if (input) {
            input.focus();
        }
    }

    /** Start over: the agent session ends and an unordered quote is deleted with the chat. */
    async handleStartOver() {
        const hadQuote = !!this.view?.quote && !this.view?.order;
        if (this.journeyKey) {
            try {
                await nfApi.agentEnd(this.journeyKey, true);
            } catch (e) {
                // the hourly cleanup removes it otherwise
            }
        }
        await this.start();
        this.notice = hadQuote ? 'Your previous cart and quote were deleted.' : null;
    }

    async handleExit() {
        if (this.journeyKey && !this.view?.order) {
            nfApi.agentEnd(this.journeyKey, true).catch(() => {});
        }
        this.dispatchEvent(new CustomEvent('exit'));
    }

    // ── Chat input ───────────────────────────────────────────────────────────

    handleDraft(event) {
        this.draft = event.target.value;
    }
    handleKeydown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.send(this.draft);
        }
    }
    handleSend() {
        this.send(this.draft);
    }
    handleSuggestion(event) {
        this.send(event.currentTarget.dataset.text);
    }

    get thinkingLabel() {
        return THINKING[this.thinkingIndex];
    }
    get sendDisabled() {
        return this.sending || this.starting || !this.journeyKey || !this.draft.trim();
    }
    get inputDisabled() {
        return this.starting || !this.journeyKey;
    }
    get suggestions() {
        const step = this.view?.step || 'address';
        if (step === 'address') {
            return SAMPLE_ADDRESSES.slice(0, 4).map((a) => ({
                key: a.postalCode,
                label: `${a.street}, ${a.city} ${a.postalCode}`,
                text: `Can I get NovaFiber at ${a.street}, ${a.city}, ${a.state} ${a.postalCode}?`
            }));
        }
        return (SUGGESTIONS[step] || []).map((text) => ({ key: text, label: text, text }));
    }
    get hasSuggestions() {
        return !this.sending && !this.starting && this.suggestions.length > 0;
    }

    // ── Journey canvas ───────────────────────────────────────────────────────

    get step() {
        return this.view?.step || 'address';
    }
    get stepsView() {
        const current = STEPS.findIndex((s) => s.key === this.step);
        return STEPS.map((s, i) => ({
            ...s,
            number: i + 1,
            cssClass: 'aj-step' + (i < current ? ' aj-step_done' : i === current ? ' aj-step_current' : ''),
            ariaCurrent: i === current ? 'step' : null
        }));
    }
    get showWelcome() {
        return !this.view?.serviceability && !this.starting;
    }
    get serviceability() {
        return this.view?.serviceability;
    }
    get appointment() {
        return this.view?.appointment;
    }
    get order() {
        return this.view?.order;
    }
    get showQuote() {
        return this.step === 'quote' && !!this.view?.quote && !this.showCheckout;
    }
    get showCheckoutForm() {
        return this.step === 'quote' && this.showCheckout;
    }
    get showShop() {
        return !!this.view?.serviceability && (this.step === 'offers' || this.step === 'cart');
    }
    get cart() {
        return this.view?.cart || [];
    }
    get cartState() {
        return this.view?.cartState;
    }
    /** Options the configuration rules (CML) block for the plans in the cart. */
    get ruleHidden() {
        return this.view?.cartState?.hiddenOptions || [];
    }
    get categoriesView() {
        const inCart = {};
        this.cart.forEach((item) => {
            inCart[item.offer.productId] = (inCart[item.offer.productId] || 0) + item.quantity;
        });
        return (this.view?.offers || []).map((c) => ({
            key: c.key,
            label: c.label,
            offers: c.offers.map((o) => ({ offer: o, inCart: inCart[o.productId] || 0 }))
        }));
    }
    get noOffers() {
        return !this.categoriesView.some((c) => c.offers.length > 0);
    }
    get customerCaptured() {
        return !!this.view?.customerCaptured;
    }

    itemByKey(key) {
        return this.cart.find((i) => i.key === key);
    }
    planRef(offer) {
        return `${offer.name} (plan code ${offer.productCode})`;
    }

    handleSelectOffer(event) {
        const offer = (this.view?.offers || []).flatMap((c) => c.offers).find((o) => o.productId === event.detail.productId);
        if (offer) {
            this.send(`Add ${this.planRef(offer)} to my cart.`);
        }
    }
    handleCartRemove(event) {
        const item = this.itemByKey(event.detail.key);
        if (item) {
            this.send(`Remove ${this.planRef(item.offer)} from my cart.`);
        }
    }
    handleCartQuantity(event) {
        const item = this.itemByKey(event.detail.key);
        if (item) {
            const quantity = Math.max(1, item.quantity + event.detail.delta);
            this.send(`Change ${this.planRef(item.offer)} to quantity ${quantity}.`);
        }
    }
    handleCartEdit(event) {
        const item = this.itemByKey(event.detail.key);
        if (item) {
            this.send(`Which add-ons can I choose for ${this.planRef(item.offer)}?`);
        }
    }
    get hasCart() {
        return this.cart.length > 0;
    }
    /** Add-on cards just ask Nova, so the agent stays in charge of the cart. */
    handleAddOn(event) {
        const { itemKey, componentId, action } = event.detail;
        const item = this.itemByKey(itemKey);
        const option = item && (item.offer.groups || []).flatMap((g) => g.options).find((o) => o.componentId === componentId);
        if (!option) {
            return;
        }
        const plan = this.planRef(item.offer);
        if (action === 'remove') {
            this.send(`Remove the ${option.name} add-on from ${plan}.`);
        } else if (action === 'switch') {
            this.send(`Switch to ${option.name} for ${plan}.`);
        } else {
            this.send(`Add the ${option.name} add-on to ${plan}.`);
        }
    }
    handleCartQuote() {
        this.send('Please save my quote.');
    }
    handleChangeAddress() {
        this.draft = 'I would like to check a different address: ';
        this.focusInput();
    }
    handleQuoteBack() {
        this.send('I want to change my plans.');
    }
    handleToCheckout() {
        this.showCheckout = true;
    }
    handleCheckoutBack() {
        this.showCheckout = false;
    }
    async handleCustomer(event) {
        if (!this.journeyKey) {
            return;
        }
        this.savingCustomer = true;
        try {
            const view = await nfApi.agentSaveCustomer(this.journeyKey, event.detail);
            this.apply(view);
            this.showCheckout = false;
            // Next: the service agreement, generated from the native template and signed on the page.
            const { portalPassword, ...signer } = event.detail; // eslint-disable-line no-unused-vars
            this.signer = signer;
            this.showAgreement = true;
        } catch (e) {
            this.push('system', reduceError(e));
        } finally {
            this.savingCustomer = false;
        }
    }
    async handleAgreementSigned() {
        this.showAgreement = false;
        await this.send('I have completed the secure checkout form and e-signed my service agreement. Please place my order.');
    }
    get showAgreementCard() {
        return this.showAgreement && this.step === 'quote' && !!this.view?.quote;
    }
    handleRestart() {
        this.handleStartOver();
    }
    /** "Track my order": open My NovaFiber (the chat stays as it is). */
    handleTrack(event) {
        this.dispatchEvent(new CustomEvent('track', { detail: event.detail }));
    }
    handleOpenRecord() {
        // customers do not open Salesforce records
    }
    get busy() {
        return this.sending || this.savingCustomer;
    }
}
