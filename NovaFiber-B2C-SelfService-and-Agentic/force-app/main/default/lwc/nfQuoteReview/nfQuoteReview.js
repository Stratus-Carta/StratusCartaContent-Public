import { LightningElement, api } from 'lwc';
import { formatMoney } from 'c/nfUtils';

export default class NfQuoteReview extends LightningElement {
    @api quote;
    @api currencyCode = 'USD';
    @api isAgent = false;
    @api busy = false;

    money(v) {
        return formatMoney(v, this.currencyCode);
    }

    toView(l) {
        const suffix = l.chargeType === 'One-Time' ? ' one-time' : '/mo';
        return {
            ...l,
            qty: Number(l.quantity),
            listLabel: l.listPrice ? this.money(l.listPrice) + suffix : 'Included',
            netLabel: l.netTotal ? this.money(l.netTotal) + suffix : '—',
            discountLabel: l.discountPercent && l.listPrice ? `-${Number(l.discountPercent)}%` : null
        };
    }

    /** Bundle parents with their components underneath, in quote order. */
    get groups() {
        const lines = this.quote?.lines || [];
        const parents = lines.filter((l) => !l.parentLineId).map((l) => ({ ...this.toView(l), children: [] }));
        const byId = new Map(parents.map((p) => [p.lineId, p]));
        lines.filter((l) => l.parentLineId).forEach((l) => {
            const parent = byId.get(l.parentLineId);
            if (parent) {
                parent.children.push(this.toView(l));
            }
        });
        return parents;
    }

    /** Revenue Cloud configurator messages that still apply to the saved quote (warnings / info). */
    get notes() {
        return (this.quote?.messages || []).map((m, i) => ({
            key: `n${i}`,
            text: m.productName ? `${m.productName}: ${m.message}` : m.message
        }));
    }
    get hasNotes() {
        return this.notes.length > 0;
    }
    get monthlyLabel() {
        return this.money(this.quote?.monthlyTotal);
    }
    get oneTimeLabel() {
        return this.money(this.quote?.oneTimeTotal);
    }
    get savingsLabel() {
        const s = Number(this.quote?.monthlySavings) || 0;
        return s > 0.004 ? this.money(s) : null;
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('back'));
    }
    handleContinue() {
        this.dispatchEvent(new CustomEvent('continue'));
    }
    handleOpen() {
        this.dispatchEvent(new CustomEvent('openrecord', { detail: { recordId: this.quote.quoteId, objectApiName: 'Quote' } }));
    }
}
