import { LightningElement, api } from 'lwc';
import { api as nfApi } from 'c/nfApi';
import { reduceError } from 'c/nfUtils';

export default class NfAgentPanel extends LightningElement {
    @api userName;
    @api maxDiscount;
    @api account;

    results = [];
    searching = false;
    timer;

    get hasResults() {
        return this.results.length > 0;
    }

    handleSearch(event) {
        const term = event.detail.value;
        clearTimeout(this.timer);
        if (!term || term.length < 2) {
            this.results = [];
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setTimeout(async () => {
            this.searching = true;
            try {
                this.results = (await nfApi.searchAccounts(term)) || [];
            } catch (e) {
                this.results = [];
                this.dispatchEvent(new CustomEvent('error', { detail: { message: reduceError(e) } }));
            } finally {
                this.searching = false;
            }
        }, 300);
    }

    handlePick(event) {
        const picked = this.results.find((r) => r.accountId === event.currentTarget.dataset.id);
        this.results = [];
        this.dispatchEvent(new CustomEvent('accountchange', { detail: { account: picked } }));
    }

    handleClear() {
        this.dispatchEvent(new CustomEvent('accountchange', { detail: { account: null } }));
    }
}
