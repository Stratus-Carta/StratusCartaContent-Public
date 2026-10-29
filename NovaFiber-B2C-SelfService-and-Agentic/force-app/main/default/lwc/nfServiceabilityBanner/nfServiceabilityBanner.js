import { LightningElement, api } from 'lwc';
import { formatSpeed } from 'c/nfUtils';

const LABELS = {
    SERVICEABLE: 'Great news — NovaFiber is available!',
    PARTIAL: 'Good news — some services are available',
    NOT_SERVICEABLE: 'Home internet is not available here yet'
};

export default class NfServiceabilityBanner extends LightningElement {
    @api result;
    @api canOverride = false;
    @api busy = false;

    get statusLabel() {
        return LABELS[this.result?.status] || this.result?.status;
    }
    get bannerClass() {
        const s = this.result?.status;
        return 'nf-banner ' + (s === 'SERVICEABLE' ? 'nf-ok' : s === 'PARTIAL' ? 'nf-partial' : 'nf-none');
    }
    get iconName() {
        const s = this.result?.status;
        return s === 'SERVICEABLE' ? 'utility:success' : s === 'PARTIAL' ? 'utility:info' : 'utility:warning';
    }
    get addressLine() {
        const a = this.result?.address || {};
        return [a.street, a.unit, a.city, `${a.state || ''} ${a.postalCode || ''}`.trim()].filter((x) => x).join(', ');
    }
    get techs() {
        return (this.result?.technologies || []).map((t) => ({ ...t, speed: formatSpeed(t.maxDownloadMbps) }));
    }
    get showOverride() {
        return this.canOverride && !this.result?.overridden && this.result?.status !== 'SERVICEABLE';
    }

    handleChangeAddress() {
        this.dispatchEvent(new CustomEvent('changeaddress'));
    }
    handleOverride() {
        this.dispatchEvent(new CustomEvent('override'));
    }
}
