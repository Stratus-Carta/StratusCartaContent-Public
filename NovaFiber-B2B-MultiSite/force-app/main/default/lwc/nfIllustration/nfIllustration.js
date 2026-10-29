import { LightningElement, api } from 'lwc';

/**
 * NovaFiber brand illustrations (inline SVG, no external assets so they work on the guest site).
 * name: hero | tv | mobile | router | technician
 */
export default class NfIllustration extends LightningElement {
    @api name = 'hero';

    get isHero() {
        return this.name === 'hero';
    }
    get isTv() {
        return this.name === 'tv';
    }
    get isMobile() {
        return this.name === 'mobile';
    }
    get isRouter() {
        return this.name === 'router';
    }
    get isTechnician() {
        return this.name === 'technician';
    }
    get wrapClass() {
        return `nf-illo nf-illo_${this.name}`;
    }
}
