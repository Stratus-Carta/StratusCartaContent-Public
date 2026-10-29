import { LightningElement, api } from 'lwc';
import { api as nfApi } from 'c/nfApi';
import { formatMoney, reduceError } from 'c/nfUtils';

const TOKEN_KEY = 'nf.portalToken';
const REFRESH_MS = 15000;

function readToken() {
    try {
        return window.sessionStorage.getItem(TOKEN_KEY);
    } catch (e) {
        return null;
    }
}
function writeToken(token) {
    try {
        if (token) {
            window.sessionStorage.setItem(TOKEN_KEY, token);
        } else {
            window.sessionStorage.removeItem(TOKEN_KEY);
        }
    } catch (e) {
        // storage unavailable: the session lasts for this page view
    }
}
function when(value) {
    if (!value) {
        return '';
    }
    return new Date(value).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}
function day(value) {
    if (!value) {
        return '';
    }
    const [y, m, d] = String(value).split('-').map(Number);
    return new Date(y, m - 1, d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

/**
 * My NovaFiber: the customer's own portal. Log in with the email and password chosen at checkout, then
 * follow each order through the Revenue Cloud DRO orchestration (network, equipment, technician, billing)
 * to activation. The page refreshes itself while an order is still in progress.
 */
export default class NfPortal extends LightningElement {
    @api currencyCode = 'USD';
    /** Pre-filled from the order confirmation ("Track my order"). */
    @api username;

    token = readToken();
    dashboard;
    email = '';
    password = '';
    loading = false;
    error;
    lastRefresh;
    timer;

    connectedCallback() {
        this.email = this.username || '';
        if (this.token) {
            this.refresh();
        }
    }

    disconnectedCallback() {
        window.clearTimeout(this.timer);
    }

    get loggedIn() {
        return !!this.dashboard;
    }
    get showLogin() {
        return !this.dashboard && !(this.loading && this.token);
    }
    get restoring() {
        return !this.dashboard && this.loading && !!this.token;
    }

    // ── Login ────────────────────────────────────────────────────────────────

    handleEmail(event) {
        this.email = event.detail.value;
    }
    handlePassword(event) {
        this.password = event.detail.value;
    }
    handleKey(event) {
        if (event.key === 'Enter') {
            this.handleLogin();
        }
    }
    async handleLogin() {
        const inputs = [...this.template.querySelectorAll('.pt-login lightning-input')];
        if (!inputs.reduce((ok, el) => el.reportValidity() && ok, true)) {
            return;
        }
        this.loading = true;
        this.error = undefined;
        try {
            const r = await nfApi.portalLogin(this.email, this.password);
            this.password = '';
            this.token = r.token;
            writeToken(r.token);
            this.show(r.dashboard);
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.loading = false;
        }
    }

    async handleLogout() {
        window.clearTimeout(this.timer);
        const token = this.token;
        this.token = null;
        this.dashboard = undefined;
        writeToken(null);
        if (token) {
            nfApi.portalLogout(token).catch(() => {});
        }
    }

    // ── Dashboard ────────────────────────────────────────────────────────────

    async refresh() {
        window.clearTimeout(this.timer);
        if (!this.token) {
            return;
        }
        this.loading = true;
        try {
            this.show(await nfApi.portalDashboard(this.token));
            this.error = undefined;
        } catch (e) {
            // expired session: back to the login form
            this.error = reduceError(e);
            this.token = null;
            this.dashboard = undefined;
            writeToken(null);
        } finally {
            this.loading = false;
        }
    }

    show(dashboard) {
        this.dashboard = dashboard;
        this.lastRefresh = new Date();
        window.clearTimeout(this.timer);
        if (dashboard && dashboard.inProgress) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.timer = window.setTimeout(() => this.refresh(), REFRESH_MS);
        }
    }

    handleRefresh() {
        this.refresh();
    }
    handleShop() {
        this.dispatchEvent(new CustomEvent('shop'));
    }

    get greeting() {
        return this.dashboard?.firstName ? `Hi ${this.dashboard.firstName}` : 'Welcome back';
    }
    get statusLabel() {
        return this.dashboard?.serviceStatus || 'No services yet';
    }
    get statusClass() {
        const s = this.dashboard?.serviceStatus;
        return 'pt-status' + (s === 'Active' ? ' pt-status_live' : s === 'Needs Attention' ? ' pt-status_warn' : '');
    }
    get liveNote() {
        if (!this.lastRefresh) {
            return '';
        }
        const at = this.lastRefresh.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit' });
        return this.dashboard?.inProgress ? `Live · updated ${at} · refreshes every 15 seconds` : `Updated ${at}`;
    }
    get hasOrders() {
        return (this.dashboard?.orders || []).length > 0;
    }
    get orders() {
        return (this.dashboard?.orders || []).map((o) => {
            const milestones = (o.milestones || []).map((m, i) => ({
                ...m,
                number: i + 1,
                isDone: m.state === 'done',
                isAttention: m.state === 'attention',
                cssClass: `pt-ms pt-ms_${m.state}`,
                when: when(m.at),
                ariaCurrent: m.state === 'current' || m.state === 'attention' ? 'step' : null
            }));
            const done = milestones.filter((m) => m.isDone).length;
            const lines = (o.lines || [])
                .filter((l) => !l.parentLineId)
                .map((l) => ({
                    key: l.lineId || l.productName,
                    name: l.quantity > 1 ? `${l.productName} ×${l.quantity}` : l.productName,
                    price: `${formatMoney(l.netTotal, this.currencyCode)}${l.chargeType === 'One-Time' ? ' one-time' : '/mo'}`
                }));
            return {
                key: o.orderNumber,
                title: `Order ${o.orderNumber}`,
                placed: `Placed ${day(o.placedOn)}`,
                statusText: o.complete ? 'Active' : o.needsAttention ? 'Needs attention' : o.fulfillmentStatus || 'Received',
                statusClass: 'pt-chip' + (o.complete ? ' pt-chip_live' : o.needsAttention ? ' pt-chip_warn' : ''),
                headline: o.needsAttention
                    ? 'Something needs our attention. Our team is on it and will contact you.'
                    : o.fulfillmentText,
                progress: `${done} of ${milestones.length} steps complete`,
                progressStyle: `width: ${milestones.length ? Math.round((100 * done) / milestones.length) : 0}%`,
                milestones,
                timeline: (o.timeline || []).map((t, i) => ({ key: `${o.orderNumber}-${i}`, when: when(t.at), text: t.text, source: t.source })),
                hasTimeline: (o.timeline || []).length > 0,
                lines,
                monthly: formatMoney(o.monthlyTotal, this.currencyCode),
                oneTime: formatMoney(o.oneTimeTotal, this.currencyCode),
                technicianVisit: o.technicianVisit,
                installDateNote: o.installDateNote
            };
        });
    }
}
