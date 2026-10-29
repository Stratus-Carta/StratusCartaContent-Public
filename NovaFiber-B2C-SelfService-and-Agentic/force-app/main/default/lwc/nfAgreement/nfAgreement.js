import { LightningElement, api } from 'lwc';
import { api as nfApi } from 'c/nfApi';
import { progressFor, reduceError } from 'c/nfUtils';
import ESIGN_RETURN from '@salesforce/resourceUrl/NF_ESignReturn';

const POLL_MS = 1500;
const SESSION_MAX_MS = 4 * 60 * 1000;   // DocuSign recipient views must be opened within 5 minutes
const ENVELOPE_POLL_MS = 15000;

/**
 * The customer's document before ordering, from native Salesforce document templates:
 *   household  service agreement (Salesforce Contracts template, Data Mappers) → DocuSign embedded signing
 *   business   proposal (Revenue Cloud quote template, context definition) → Salesforce Contracts e-signature (email)
 * Falls back to a typed-name sandbox signature while DocuSign is not connected. Fires `signed` when done; the signed
 * card then offers `continueLabel` (fires `continue`) so ordering stays a separate, visible step.
 * DocuSign is prepared in the background as soon as the document exists (envelope, recipient view and the signing
 * page loading in a hidden frame), so "Review and sign" opens it straight away.
 */
export default class NfAgreement extends LightningElement {
    @api quoteId;
    /** CustomerDetails of the signer (name, email, phone); the password never reaches this component. */
    @api signer;
    @api isAgent = false;
    /** Button on the signed card (e.g. "Place my order"); none when the parent shows its own next step. */
    @api continueLabel;

    state; // AgreementState
    session; // SigningSession
    sessionAt;
    preparing;
    confirming = false;
    loading = false;
    error;
    typedName = '';
    consent = false;
    signing = false;
    showDocuSign = false;
    pollTimer;
    envelopeTimer;
    messageHandler;

    connectedCallback() {
        this.messageHandler = (event) => this.handleMessage(event);
        window.addEventListener('message', this.messageHandler);
        this.prepare();
    }
    disconnectedCallback() {
        window.removeEventListener('message', this.messageHandler);
        window.clearTimeout(this.pollTimer);
        window.clearTimeout(this.envelopeTimer);
    }

    // ── Generation ───────────────────────────────────────────────────────────

    async prepare() {
        this.error = undefined;
        this.loading = true;
        try {
            this.apply(await nfApi.prepareAgreement(this.quoteId, this.signer));
        } catch (e) {
            this.error = reduceError(e);
            this.loading = false;
        }
    }

    apply(state) {
        this.state = state;
        this.loading = false;
        if (state.status === 'Generating' && state.processId) {
            this.loading = true;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.pollTimer = window.setTimeout(() => this.poll(state.processId), POLL_MS);
        } else if (state.status === 'Failed') {
            this.error = state.message;
        } else if (state.status === 'Generated' && state.provider === 'DocuSign') {
            this.prepareDocuSign();
        } else if (state.status === 'Signed') {
            this.showDocuSign = false;
            this.dispatchEvent(new CustomEvent('signed', { detail: state }));
        }
    }

    async poll(processId) {
        try {
            this.apply(await nfApi.getAgreement(this.quoteId, processId));
        } catch (e) {
            this.error = reduceError(e);
            this.loading = false;
        }
    }

    // ── View helpers ─────────────────────────────────────────────────────────

    get isProposal() {
        return this.state?.kind === 'proposal';
    }
    get heading() {
        if (this.isProposal) return this.isAgent ? 'Business proposal' : 'Your business proposal';
        return this.isAgent ? 'Home service agreement' : 'Your service agreement';
    }
    get sourceNote() {
        return this.isProposal
            ? 'Revenue Cloud quote document · template "NovaFiber Business Proposal" · data from context definition NF_ProposalContext'
            : 'Salesforce Contracts · template "NovaFiber Home Service Agreement" · data from Data Mappers NFHomeAgreementExtract → Transform';
    }
    get isGenerating() {
        return this.loading && !this.state?.documentUrl;
    }
    get isReady() {
        return this.state && ['Generated', 'Sent'].includes(this.state.status) && !this.isSigned;
    }
    get isSigned() {
        return this.state?.status === 'Signed';
    }
    get signerName() {
        return `${this.signer?.firstName || ''} ${this.signer?.lastName || ''}`.trim();
    }
    get provider() {
        return this.state?.provider;
    }
    get isDocuSign() {
        return this.provider === 'DocuSign';
    }
    get isContracts() {
        return this.provider === 'Salesforce Contracts';
    }
    get isSandbox() {
        return this.provider === 'Sandbox';
    }
    get isSent() {
        return this.state?.status === 'Sent' && this.isContracts;
    }
    get providerNote() {
        if (this.isDocuSign) return 'Sign securely with DocuSign, right here on the page.';
        if (this.isContracts) return `Salesforce Contracts sends the proposal to ${this.signer?.email} through DocuSign for signature.`;
        return 'E-signature (sandbox): DocuSign is not connected yet, so the signature is recorded by NovaFiber.';
    }
    get signerLabel() {
        return `Type your full name to sign (${this.signerName})`;
    }
    /** Agents may order a household plan on verbal acceptance; business proposals always need the signature. */
    get showSkip() {
        return !this.isProposal;
    }
    get signDisabled() {
        return this.signing || !this.consent || this.typedName.trim().toLowerCase() !== this.signerName.toLowerCase();
    }
    get typedPreview() {
        return this.typedName || this.signerName;
    }
    get signedLine() {
        return `Signed by ${this.state?.signerName || this.signerName}${this.state?.signedAt ? ' on ' + this.state.signedAt : ''}`;
    }
    get generatingProgress() {
        return progressFor(this.isProposal || this.signer?.isBusiness ? 'proposal' : 'agreement');
    }
    get generatingHeading() {
        return this.isProposal || this.signer?.isBusiness ? 'Preparing the business proposal' : 'Preparing your service agreement';
    }
    get generatingSteps() {
        const proposal = this.isProposal || this.signer?.isBusiness;
        return proposal
            ? ['Quote values stamped for the proposal', 'Context Service hydrates NF_ProposalContext from the quote',
               'Document Generation renders the Word template to PDF', 'Proposal filed as the contract document version']
            : ['Contract created from your quote (Salesforce Contracts)', 'Data Mappers read the contract, quote lines and your details',
               'Document Generation renders the Word template to PDF'];
    }

    // ── Signing ──────────────────────────────────────────────────────────────

    handleTyped(event) {
        this.typedName = event.detail.value || '';
    }
    handleConsent(event) {
        this.consent = event.detail.checked;
    }

    /** Creates the DocuSign session now; its signing page loads in a hidden frame until the customer opens it. */
    prepareDocuSign() {
        if (this.preparing || (this.session && Date.now() - this.sessionAt < SESSION_MAX_MS)) {
            return this.preparing;
        }
        this.preparing = nfApi
            .startSigning(this.quoteId, this.signer, this.returnUrl(), window.location.origin)
            .then((session) => {
                this.session = session;
                this.sessionAt = Date.now();
            })
            .catch((e) => {
                this.error = reduceError(e);
            })
            .finally(() => {
                this.preparing = undefined;
            });
        return this.preparing;
    }
    get docuSignLoaded() {
        return !!this.session?.signingUrl;
    }
    get hiddenAria() {
        return this.showDocuSign ? 'false' : 'true';
    }
    get docuSignStatus() {
        if (this.confirming) return 'Confirming your signature with DocuSign…';
        return this.docuSignLoaded ? 'DocuSign is ready.' : 'Preparing DocuSign…';
    }
    get modalClass() {
        return this.showDocuSign ? 'ag-modal' : 'ag-modal ag-modal_hidden';
    }
    get showContinue() {
        return !!this.continueLabel;
    }
    handleContinue() {
        this.dispatchEvent(new CustomEvent('continue', { detail: this.state }));
    }

    returnUrl() {
        return new URL(ESIGN_RETURN, window.location.href).href;
    }

    async handleStart() {
        this.error = undefined;
        this.signing = true;
        try {
            if (this.isDocuSign) {
                if (this.session && Date.now() - this.sessionAt >= SESSION_MAX_MS) {
                    this.session = undefined;   // the prepared view expired: make a fresh one
                }
                await this.prepareDocuSign();
                if (this.session) this.showDocuSign = true;
                return;
            }
            this.session = await nfApi.startSigning(this.quoteId, this.signer, this.returnUrl(), window.location.origin);
            if (this.session.provider === 'Salesforce Contracts') {
                this.state = { ...this.state, status: 'Sent', envelopeId: this.session.envelopeId };
                this.scheduleEnvelopeCheck();
            }
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.signing = false;
        }
    }

    /** Sandbox: start (if needed) and complete with the typed signature. */
    async handleSandboxSign() {
        this.error = undefined;
        this.signing = true;
        try {
            if (!this.session) {
                this.session = await nfApi.startSigning(this.quoteId, this.signer, this.returnUrl(), window.location.origin);
            }
            this.apply(await nfApi.completeSigning(this.quoteId, this.session.envelopeId, this.signer, this.typedName));
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.signing = false;
        }
    }

    /** DocuSign returns to NF_ESignReturn, which posts { type: 'nf-esign', event } to this page. */
    async handleMessage(event) {
        const data = event?.data;
        if (!data || data.type !== 'nf-esign' || !this.session || this.isSigned) {
            return;
        }
        this.showDocuSign = false;
        if (data.event !== 'signing_complete') {
            this.error = data.event === 'decline' ? 'You declined to sign. You can review the agreement and sign again.' : 'Signing was not finished.';
            return;
        }
        await this.checkEnvelope();
    }

    /** DocuSign can report the envelope as completed a moment after the signer finishes: retry briefly. */
    async checkEnvelope(attempt = 0) {
        this.signing = true;
        try {
            const state = await nfApi.completeSigning(this.quoteId, this.session?.envelopeId || this.state?.envelopeId, this.signer, null);
            this.apply(state);
            this.confirming = state.status !== 'Signed' && this.isDocuSign && attempt < 15;
            if (this.confirming) {
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                this.envelopeTimer = window.setTimeout(() => this.checkEnvelope(attempt + 1), 2000);
            } else if (state.status !== 'Signed' && this.isContracts) {
                this.state = { ...state, message: state.message };
                this.scheduleEnvelopeCheck();
            }
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.signing = false;
        }
    }

    scheduleEnvelopeCheck() {
        window.clearTimeout(this.envelopeTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.envelopeTimer = window.setTimeout(() => this.checkEnvelope(), ENVELOPE_POLL_MS);
    }

    handleCheckNow() {
        this.checkEnvelope();
    }
    handleCloseDocuSign() {
        // A closed view can't be reopened: prepare a fresh one in the background.
        this.showDocuSign = false;
        this.session = undefined;
        this.prepareDocuSign();
    }
    handleRegenerate() {
        this.session = undefined;
        this.prepare();
    }
    handleSkip() {
        this.dispatchEvent(new CustomEvent('skip'));
    }
}
