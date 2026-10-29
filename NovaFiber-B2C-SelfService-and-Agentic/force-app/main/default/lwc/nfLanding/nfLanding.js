import { LightningElement, api } from 'lwc';
import { formatMoney } from 'c/nfUtils';

/**
 * Public landing content for the self-service site: hero (the address form is slotted in
 * as slot="form"), live plan preview from the catalog, TV/mobile, how it works, FAQ.
 */
export default class NfLanding extends LightningElement {
    @api heroTitle;
    @api heroSubtitle;
    @api currencyCode = 'USD';
    /** OfferCategory[] from NF_JourneyController.getCatalogPreview */
    @api preview = [];

    category(code) {
        return (this.preview || []).find((c) => c.key === code);
    }

    get plans() {
        const fiber = this.category('NF_CAT_FIBER');
        if (!fiber) {
            return [];
        }
        return fiber.offers
            .map((o) => ({
                ...o,
                shortName: o.name.replace('NovaFiber ', ''),
                priceLabel: formatMoney(o.price, this.currencyCode),
                cardClass: 'nf-plan' + (o.isFeatured ? ' nf-plan_featured' : ''),
                buttonClass: 'nf-btn ' + (o.isFeatured ? 'nf-btn_primary' : 'nf-btn_outline')
            }));
    }
    get hasPlans() {
        return this.plans.length > 0;
    }

    lowest(code) {
        const c = this.category(code);
        if (!c || !c.offers.length) {
            return null;
        }
        return formatMoney(Math.min(...c.offers.map((o) => o.price)), this.currencyCode);
    }
    get tvFrom() {
        return this.lowest('NF_CAT_TV');
    }
    get mobileFrom() {
        return this.lowest('NF_CAT_MOBILE');
    }

    handleChoose(event) {
        this.dispatchEvent(new CustomEvent('chooseplan', { detail: { productId: event.currentTarget.dataset.id } }));
    }
}
