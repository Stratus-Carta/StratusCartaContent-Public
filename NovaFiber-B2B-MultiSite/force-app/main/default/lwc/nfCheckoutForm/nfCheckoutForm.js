import { LightningElement, api } from 'lwc';

function isoDate(d) {
    const pad = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export default class NfCheckoutForm extends LightningElement {
    @api isAgent = false;
    @api busy = false;
    @api accountName;

    customer = {
        firstName: '',
        lastName: '',
        email: '',
        phone: '',
        preferredInstallDate: isoDate(new Date(Date.now() + 7 * 86400000)),
        acceptedTerms: false,
        portalPassword: ''
    };
    confirmPassword = '';

    /** Customers create their My NovaFiber login at checkout; agents don't set customer passwords. */
    get askPassword() {
        return !this.isAgent;
    }

    get minDate() {
        return isoDate(new Date(Date.now() + 86400000));
    }
    get heading() {
        return this.isAgent ? 'Customer details' : 'Almost there!';
    }
    get subheading() {
        if (this.isAgent) {
            return this.accountName
                ? `The order will be placed on ${this.accountName}. Capture the primary contact for installation.`
                : 'Capture the customer details and preferred installation date.';
        }
        return 'Tell us who you are and when you would like us to connect you.';
    }
    get termsLabel() {
        return this.isAgent
            ? 'Customer verbally accepted the NovaFiber terms of service'
            : 'I agree to the NovaFiber terms of service and privacy policy';
    }
    get termsRequired() {
        return !this.isAgent;
    }
    get submitLabel() {
        return this.isAgent ? 'Continue to agreement' : 'Review and sign agreement';
    }

    handleChange(event) {
        this.customer = { ...this.customer, [event.target.name]: event.detail.value };
    }
    handleCheck(event) {
        this.customer = { ...this.customer, acceptedTerms: event.detail.checked };
    }
    handleConfirm(event) {
        this.confirmPassword = event.detail.value;
    }

    /** Same rules as NF_PortalService.checkPasswordRules. */
    checkPassword() {
        const pw = this.template.querySelector('lightning-input[name="portalPassword"]');
        const confirm = this.template.querySelector('lightning-input[name="confirmPassword"]');
        if (!pw || !confirm) {
            return true;
        }
        const value = this.customer.portalPassword || '';
        pw.setCustomValidity(value.length >= 10 && /[A-Za-z]/.test(value) && /[0-9]/.test(value)
            ? '' : 'Use at least 10 characters with letters and numbers');
        confirm.setCustomValidity(value === this.confirmPassword ? '' : 'The passwords don\'t match');
        return true;
    }
    handleBack() {
        this.dispatchEvent(new CustomEvent('back'));
    }
    handleSubmit() {
        this.checkPassword();
        const inputs = [...this.template.querySelectorAll('lightning-input')];
        const valid = inputs.reduce((ok, el) => el.reportValidity() && ok, true);
        if (!valid) {
            return;
        }
        const detail = { ...this.customer };
        if (!this.askPassword) {
            delete detail.portalPassword;
        }
        this.dispatchEvent(new CustomEvent('submit', { detail }));
    }
}
