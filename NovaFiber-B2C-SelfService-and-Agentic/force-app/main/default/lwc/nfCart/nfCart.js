import { LightningElement, api } from 'lwc';
import { estimateItem, formatMoney } from 'c/nfUtils';

const MAX_LINES = 5;

/**
 * Cart side panel. Items are the UI cart; cartState is the live Revenue Cloud configurator result
 * for that cart (prices per item, rule / bundle validation messages, draft quote). While a change is
 * being configured (syncing), list-price estimates are shown.
 */
export default class NfCart extends LightningElement {
    @api items = [];
    /** NF_JourneyModels.QuoteSummary from NF_JourneyController.syncCart */
    @api cartState;
    @api syncing = false;
    @api currencyCode = 'USD';
    @api isAgent = false;
    @api maxDiscount = 0;
    @api busy = false;

    get isEmpty() {
        return !this.items || this.items.length === 0;
    }
    get hasItems() {
        return !this.isEmpty;
    }
    get countLabel() {
        const n = this.items ? this.items.length : 0;
        return n === 1 ? '1 item' : `${n} items`;
    }
    get ctaLabel() {
        return this.isAgent ? 'Save quote' : 'See my quote';
    }
    get discountMessage() {
        return `Max ${this.maxDiscount}%`;
    }

    /** Revenue Cloud prices apply when the configurator result covers every cart item. */
    get priced() {
        const lines = this.cartState?.lines;
        if (this.syncing || !lines || !lines.length) {
            return false;
        }
        const keys = new Set(lines.map((l) => l.itemKey));
        return (this.items || []).every((i) => keys.has(i.key));
    }

    pricedTotals(itemKey) {
        return (this.cartState.lines || [])
            .filter((l) => l.itemKey === itemKey)
            .reduce(
                (acc, l) => {
                    const net = Number(l.netTotal) || 0;
                    if (l.chargeType === 'One-Time') {
                        acc.oneTime += net;
                    } else {
                        acc.monthly += net;
                    }
                    return acc;
                },
                { monthly: 0, oneTime: 0 }
            );
    }

    messagesFor(itemKey) {
        return (this.cartState?.messages || [])
            .filter((m) => (m.itemKey || null) === itemKey)
            .map((m, i) => {
                // CML: a rule changed the options (cml) or a message rule fired (configurationrules)
                const rule = m.severity !== 'error' && (m.category === 'cml' || m.category === 'configurationrules');
                const level = m.severity === 'error' ? 'error' : m.severity === 'warning' ? 'warning' : 'info';
                return {
                    key: `${itemKey || 'cart'}-${i}`,
                    text: m.message,
                    cssClass: 'nf-cart-msg nf-cart-msg_' + (rule ? 'rule' : level),
                    icon: rule ? 'utility:rules' : level === 'error' ? 'utility:error' : level === 'warning' ? 'utility:warning' : 'utility:info'
                };
            });
    }

    get cartMessages() {
        return this.syncing ? [] : this.messagesFor(null);
    }
    get hasCartMessages() {
        return this.cartMessages.length > 0;
    }

    get rows() {
        const priced = this.priced;
        return (this.items || []).map((item) => {
            const totals = priced ? this.pricedTotals(item.key) : estimateItem(item);
            const optionNames = (item.offer.groups || [])
                .flatMap((g) => g.options)
                .filter((o) => item.options[o.componentId])
                .map((o) => (item.options[o.componentId] > 1 ? `${o.name} ×${item.options[o.componentId]}` : o.name))
                .join(' · ');
            const messages = this.syncing ? [] : this.messagesFor(item.key);
            return {
                key: item.key,
                name: item.quantity > 1 ? `${item.offer.name} ×${item.quantity}` : item.offer.name,
                isBundle: item.offer.isBundle,
                quantity: item.quantity,
                atMin: item.quantity <= 1,
                atMax: item.quantity >= MAX_LINES,
                optionNames,
                discountPercent: item.discountPercent,
                monthlyLabel: formatMoney(totals.monthly, this.currencyCode),
                oneTimeLabel: totals.oneTime ? formatMoney(totals.oneTime, this.currencyCode) : null,
                messages,
                hasMessages: messages.length > 0
            };
        });
    }

    get totals() {
        if (this.priced) {
            return { monthly: Number(this.cartState.monthlyTotal) || 0, oneTime: Number(this.cartState.oneTimeTotal) || 0 };
        }
        return (this.items || []).reduce(
            (acc, item) => {
                const est = estimateItem(item);
                acc.monthly += est.monthly;
                acc.oneTime += est.oneTime;
                return acc;
            },
            { monthly: 0, oneTime: 0 }
        );
    }
    get totalLabel() {
        return this.priced ? 'Monthly' : 'Estimated monthly';
    }
    get totalMonthlyLabel() {
        return formatMoney(this.totals.monthly, this.currencyCode);
    }
    get totalOneTimeLabel() {
        return formatMoney(this.totals.oneTime, this.currencyCode);
    }
    get statusText() {
        if (this.syncing) {
            return 'Checking your selection with Revenue Cloud…';
        }
        if (this.priced) {
            const source = this.cartState.fromCache ? 'Priced by Revenue Cloud earlier (from cache)' : 'Configured and priced by Revenue Cloud';
            return `${source}${this.cartState.quoteNumber ? ' · quote ' + this.cartState.quoteNumber : ''}. Taxes not included.`;
        }
        return 'Prices are confirmed by Revenue Cloud when you change your cart. Taxes not included.';
    }
    get ctaDisabled() {
        return this.busy || this.syncing || this.cartState?.hasErrors === true;
    }

    fire(name, detail) {
        this.dispatchEvent(new CustomEvent(name, { detail }));
    }
    handleEdit(event) {
        this.fire('edit', { key: event.currentTarget.dataset.key });
    }
    handleRemove(event) {
        this.fire('remove', { key: event.currentTarget.dataset.key });
    }
    handleQty(event) {
        const { key, delta } = event.currentTarget.dataset;
        this.fire('quantity', { key, delta: Number(delta) });
    }
    handleDiscount(event) {
        const value = event.detail.value === '' ? null : Math.max(0, Math.min(this.maxDiscount, Number(event.detail.value)));
        this.fire('discount', { key: event.target.dataset.key, value });
    }
    handleQuote() {
        this.fire('quote');
    }
}
