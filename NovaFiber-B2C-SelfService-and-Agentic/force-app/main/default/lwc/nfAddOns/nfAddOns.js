import { LightningElement, api } from 'lwc';
import { formatMoney } from 'c/nfUtils';

/**
 * Add-ons section: the bundle options (equipment, installation, services) of each plan in the cart,
 * from Revenue Cloud Product Discovery. Fires `addon` { itemKey, componentId, action: add | remove | switch }.
 */
export default class NfAddOns extends LightningElement {
    /** Cart items: { key, offer, quantity, options: { componentId: quantity } } */
    @api items = [];
    @api currencyCode = 'USD';
    @api busy = false;
    @api highlight = false;
    /** Options the configuration rules (CML) hide or disable: [{ itemKey, componentId, treatment }] */
    @api hiddenOptions = [];

    get sections() {
        return (this.items || [])
            .filter((item) => item.offer && (item.offer.groups || []).length > 0)
            .map((item) => ({
                key: item.key,
                title: `Add-ons for ${item.offer.name}`,
                groups: item.offer.groups.map((g) => {
                    const chosenInGroup = g.options.some((o) => item.options[o.componentId]);
                    return {
                        key: `${item.key}-${g.groupId || g.name}`,
                        name: g.name,
                        hint: g.maxOptions === 1 ? 'Choose one' : g.minOptions > 0 ? `At least ${g.minOptions}` : 'Optional',
                        options: g.options.map((o) => {
                            const selected = !!item.options[o.componentId];
                            const ruled = (this.hiddenOptions || []).some((h) => h.itemKey === item.key && h.componentId === o.componentId);
                            const isSwitch = !selected && g.maxOptions === 1 && chosenInGroup;
                            let action = selected ? 'remove' : isSwitch ? 'switch' : 'add';
                            if (o.isRequired || ruled) {
                                action = null;
                            }
                            const price = Number(o.price) || 0;
                            return {
                                key: o.componentId,
                                itemKey: item.key,
                                componentId: o.componentId,
                                name: o.name,
                                tagline: o.tagline,
                                priceLabel: price ? formatMoney(price, this.currencyCode) : 'Included',
                                unitLabel: price ? (o.chargeType === 'One-Time' ? 'one-time' : '/mo') : '',
                                stateLabel: o.isRequired ? 'Required' : selected ? 'In your cart' : null,
                                ruled,
                                cssClass: 'ao-card' + (selected || o.isRequired ? ' ao-card_on' : '') + (ruled ? ' ao-card_ruled' : ''),
                                action,
                                hasAction: !!action,
                                buttonLabel: action === 'remove' ? 'Remove' : action === 'switch' ? 'Switch to this' : 'Add',
                                buttonClass: 'ao-btn' + (action === 'remove' ? ' ao-btn_ghost' : '')
                            };
                        })
                    };
                })
            }));
    }
    get hasSections() {
        return this.sections.length > 0;
    }
    get rootClass() {
        return 'ao' + (this.highlight ? ' ao_highlight' : '');
    }

    handleClick(event) {
        const { itemKey, componentId, action } = event.currentTarget.dataset;
        this.dispatchEvent(new CustomEvent('addon', { detail: { itemKey, componentId, action } }));
    }
}
