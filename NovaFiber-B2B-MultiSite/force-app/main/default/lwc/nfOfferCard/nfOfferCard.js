import { LightningElement, api } from 'lwc';
import { formatMoney, formatSpeed } from 'c/nfUtils';

export default class NfOfferCard extends LightningElement {
    @api offer;
    @api currencyCode = 'USD';
    @api inCartQuantity = 0;
    @api disabled = false;

    get cardClass() {
        return 'nf-offer' + (this.offer.isFeatured ? ' nf-featured' : '') + (this.inCartQuantity ? ' nf-selected' : '');
    }
    get price() {
        return formatMoney(this.offer.price, this.currencyCode);
    }
    get unit() {
        return this.offer.chargeType === 'One-Time' ? ' one-time' : '/mo';
    }
    get speedLabel() {
        if (!this.offer.downloadMbps) {
            return null;
        }
        const down = formatSpeed(this.offer.downloadMbps);
        const up = formatSpeed(this.offer.uploadMbps);
        return up && up !== down ? `${down} down / ${up} up` : `${down} symmetrical`;
    }
    get buttonLabel() {
        if (this.offer.isBundle) {
            return this.inCartQuantity ? 'Add another' : 'Choose plan';
        }
        return this.inCartQuantity ? 'Add another line' : 'Add to cart';
    }
    get buttonVariant() {
        return this.offer.isFeatured ? 'brand' : 'brand-outline';
    }

    handleSelect() {
        this.dispatchEvent(new CustomEvent('select', { detail: { productId: this.offer.productId } }));
    }
}
