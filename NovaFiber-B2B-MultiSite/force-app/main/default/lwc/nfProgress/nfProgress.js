import { LightningElement, api } from 'lwc';

const TIP_MS = 4500;

/**
 * Keeps people engaged while a slow server step runs: the steps it goes through tick off one by one at their
 * expected pace (the last one stays active until the work is done and the component goes away), an animated
 * bar fills toward ~95 %, and a rotating "good to know" line.
 *   variant "toast"  floating card at the bottom of the screen (page-level busy state)
 *   variant "card"   inline, inside a card (e.g. the agreement while it generates)
 */
export default class NfProgress extends LightningElement {
    @api heading;
    /** [{ label, ms }] — ms = how long the step usually takes. */
    @api steps = [];
    @api tips = [];
    @api variant = 'toast';

    elapsed = 0;
    tipIndex = 0;
    timer;
    tipTimer;
    started;

    connectedCallback() {
        this.started = Date.now();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = window.setInterval(() => {
            this.elapsed = Date.now() - this.started;
        }, 200);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.tipTimer = window.setInterval(() => {
            if (this.tips?.length) this.tipIndex = (this.tipIndex + 1) % this.tips.length;
        }, TIP_MS);
    }
    disconnectedCallback() {
        window.clearInterval(this.timer);
        window.clearInterval(this.tipTimer);
    }

    get total() {
        return (this.steps || []).reduce((s, x) => s + (x.ms || 1500), 0) || 4000;
    }
    get stepViews() {
        let at = 0;
        const steps = this.steps || [];
        return steps.map((s, i) => {
            const start = at;
            at += s.ms || 1500;
            const last = i === steps.length - 1;
            const done = !last && this.elapsed >= at;
            const active = !done && this.elapsed >= start;
            return {
                key: `s${i}`,
                label: s.label,
                className: `pg-step${done ? ' pg-step_done' : ''}${active ? ' pg-step_active' : ''}`,
                done,
                active
            };
        });
    }
    get current() {
        const v = this.stepViews.find((s) => s.active);
        return v ? v.label : this.heading;
    }
    get barStyle() {
        // eases toward 95 %, never "finishes" before the work does
        const p = 95 * (1 - Math.exp(-2.2 * (this.elapsed / this.total)));
        return `width:${p.toFixed(1)}%`;
    }
    get tip() {
        return this.tips?.length ? this.tips[this.tipIndex % this.tips.length] : null;
    }
    get isToast() {
        return this.variant !== 'card';
    }
    get rootClass() {
        return this.isToast ? 'pg pg_toast' : 'pg pg_card';
    }
    get seconds() {
        return Math.floor(this.elapsed / 1000) + ' s';
    }
}
