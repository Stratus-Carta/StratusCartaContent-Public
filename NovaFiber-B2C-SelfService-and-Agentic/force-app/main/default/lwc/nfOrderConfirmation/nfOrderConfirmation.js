import { LightningElement, api } from 'lwc';
import { formatMoney } from 'c/nfUtils';

export default class NfOrderConfirmation extends LightningElement {
    @api order;
    @api currencyCode = 'USD';
    @api isAgent = false;
    /** Installation booked by Nova in the chat (agent journey); the calendar books it on the page otherwise. */
    @api
    get appointment() {
        return this.bookedAppointment;
    }
    set appointment(value) {
        if (value && value.appointmentId) {
            this.bookedAppointment = value;
        }
    }
    bookedAppointment;

    get heading() {
        return this.isAgent ? 'Order placed' : 'Thank you! Your order is in.';
    }
    get monthlyLabel() {
        return formatMoney(this.order?.monthlyTotal, this.currencyCode);
    }
    get oneTimeLabel() {
        return formatMoney(this.order?.oneTimeTotal, this.currencyCode);
    }
    get installHeading() {
        return this.bookedAppointment ? 'Installation' : 'Preferred install';
    }
    get bookingHeading() {
        return this.isAgent ? 'Book the installation visit' : 'Book your installation';
    }
    handleBooked(event) {
        this.bookedAppointment = event.detail.appointment;
    }
    get installLabel() {
        if (this.bookedAppointment?.dateLabel) {
            return this.bookedAppointment.dateLabel.replace(/^(\w{3})\w*,/, '$1,');
        }
        if (!this.order?.installDate) {
            return '—';
        }
        const [y, m, d] = String(this.order.installDate).split('-').map(Number);
        return new Date(y, m - 1, d).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
    }
    get restartLabel() {
        return this.isAgent ? 'Start a new sale' : 'Back to start';
    }

    handleOpen() {
        this.dispatchEvent(new CustomEvent('openrecord', { detail: { recordId: this.order.orderId, objectApiName: 'Order' } }));
    }
    handleRestart() {
        this.dispatchEvent(new CustomEvent('restart'));
    }
    get inFulfillment() {
        return this.order?.submittedToFulfillment === true;
    }
    get canTrack() {
        return !this.isAgent && !!this.order?.portalUsername;
    }
    handleTrack() {
        this.dispatchEvent(new CustomEvent('track', { detail: { username: this.order.portalUsername } }));
    }
}
