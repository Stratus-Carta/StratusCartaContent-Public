import { LightningElement, api } from 'lwc';
import { SAMPLE_ADDRESSES, US_STATES } from 'c/nfUtils';

export default class NfAddressForm extends LightningElement {
    @api busy = false;
    @api hint;

    @api
    focusFirst() {
        const first = this.template.querySelector('lightning-input');
        if (first) {
            first.focus();
        }
    }

    samples = SAMPLE_ADDRESSES;
    states = US_STATES;
    address = { street: '', unit: '', city: '', state: '', postalCode: '', country: 'US' };

    @api
    set value(v) {
        if (v) {
            this.address = { ...this.address, ...v };
        }
    }
    get value() {
        return this.address;
    }

    handleChange(event) {
        this.address = { ...this.address, [event.target.name]: event.detail.value };
    }

    handleSample(event) {
        const s = SAMPLE_ADDRESSES.find((a) => a.postalCode === event.currentTarget.dataset.zip);
        this.address = { street: s.street, unit: '', city: s.city, state: s.state, postalCode: s.postalCode, country: 'US' };
    }

    handleSubmit() {
        const inputs = [...this.template.querySelectorAll('lightning-input, lightning-combobox')];
        const valid = inputs.reduce((ok, el) => el.reportValidity() && ok, true);
        if (!valid) {
            return;
        }
        this.dispatchEvent(new CustomEvent('check', { detail: { ...this.address } }));
    }
}
