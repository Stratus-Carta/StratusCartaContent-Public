import { LightningElement, api } from 'lwc';
import { defaultSelections, estimateItem, formatMoney } from 'c/nfUtils';

/**
 * Bundle configurator for one offer. Mirrors the Revenue Cloud bundle structure
 * (ProductComponentGroup min/max, ProductRelatedComponent required/default/quantity);
 * the server re-validates everything when the quote is priced.
 */
export default class NfOfferConfigurator extends LightningElement {
    @api currencyCode = 'USD';
    @api editing = false;
    /** Options the configuration rules (CML) hide or disable for this item: { componentId: 'hide' | 'disable' }. */
    @api ruleHidden = {};
    selections = {};
    error;
    _offer;
    _initial;

    // Property assignment order is not guaranteed, so either setter may run first.
    @api
    set offer(value) {
        this._offer = value;
        this.selections = this._initial ? { ...this._initial } : defaultSelections(value);
    }
    get offer() {
        return this._offer;
    }

    @api
    set initialSelections(value) {
        this._initial = value;
        if (value) {
            this.selections = { ...value };
        }
    }
    get initialSelections() {
        return this.selections;
    }

    get groupsView() {
        return (this.offer.groups || []).map((g) => {
            const single = g.maxOptions === 1;
            const selectedCount = g.options.filter((o) => this.selections[o.componentId]).length;
            const maxReached = g.maxOptions && selectedCount >= g.maxOptions;
            let rule;
            if (single) {
                rule = g.minOptions ? 'Choose one' : 'Optional — choose up to one';
            } else if (g.minOptions) {
                rule = `Choose ${g.minOptions} to ${g.maxOptions}`;
            } else {
                rule = `Optional — up to ${g.maxOptions}`;
            }
            return {
                ...g,
                rule,
                inputType: single && g.minOptions ? 'radio' : 'checkbox',
                options: g.options.map((o) => {
                    const qty = this.selections[o.componentId] || 0;
                    const checked = qty > 0;
                    const ruled = !!(this.ruleHidden || {})[o.componentId];
                    return {
                        ...o,
                        checked,
                        quantity: qty,
                        locked: o.isRequired || ruled || (!single && !checked && maxReached),
                        ruled,
                        showQuantity: checked && o.isQuantityEditable,
                        atMin: qty <= o.minQuantity,
                        atMax: qty >= o.maxQuantity,
                        priceLabel: this.priceLabel(o),
                        cssClass: 'nf-option' + (checked ? ' nf-option_on' : '') + (ruled ? ' nf-option_ruled' : '')
                    };
                })
            };
        });
    }

    priceLabel(o) {
        if (!o.price) {
            return 'Included';
        }
        const amount = formatMoney(o.price, this.currencyCode);
        return o.chargeType === 'One-Time' ? `${amount} one-time` : `+${amount}/mo`;
    }

    get estimate() {
        return estimateItem({ offer: this.offer, quantity: 1, options: this.selections });
    }
    get monthlyLabel() {
        return formatMoney(this.estimate.monthly, this.currencyCode);
    }
    get oneTimeLabel() {
        return this.estimate.oneTime ? formatMoney(this.estimate.oneTime, this.currencyCode) : null;
    }
    get confirmLabel() {
        return this.editing ? 'Update cart' : 'Add to cart';
    }

    handleToggle(event) {
        const { group: groupId, id } = event.target.dataset;
        const group = this.offer.groups.find((g) => g.groupId === groupId);
        const option = group.options.find((o) => o.componentId === id);
        const next = { ...this.selections };
        if (event.target.type === 'radio') {
            group.options.forEach((o) => delete next[o.componentId]);
            next[id] = option.defaultQuantity || 1;
        } else if (event.target.checked) {
            next[id] = option.defaultQuantity || 1;
        } else {
            delete next[id];
        }
        this.selections = next;
        this.error = undefined;
    }

    handleQty(event) {
        const { id, delta } = event.currentTarget.dataset;
        const option = this.offer.groups.flatMap((g) => g.options).find((o) => o.componentId === id);
        const qty = Math.min(option.maxQuantity, Math.max(option.minQuantity, (this.selections[id] || 0) + Number(delta)));
        this.selections = { ...this.selections, [id]: qty };
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleConfirm() {
        for (const g of this.offer.groups || []) {
            const count = g.options.filter((o) => this.selections[o.componentId]).length;
            if (count < g.minOptions) {
                this.error = `Please choose an option for ${g.name}.`;
                return;
            }
        }
        this.dispatchEvent(new CustomEvent('confirm', { detail: { selections: { ...this.selections } } }));
    }
}
